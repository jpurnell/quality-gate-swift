import ArgumentParser
import Foundation
#if canImport(os)
import os
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif
import QualityGateCore
import NarrativeCore
import IJSSensor
import IJSAggregator
import IJSDashboardCore

/// Which narrative engine(s) to use, in the durability chain.
enum ProviderChoice: String, ExpressibleByArgument, CaseIterable {
    /// Claude → on-device Foundation Models → preserved prior (the default chain).
    case auto
    /// Cloud Claude only.
    case claude
    /// On-device Foundation Models only.
    case onDevice = "on-device"
    /// Carry the previous pulse's narrative forward.
    case preserved
}

struct GenerateNarrative: AsyncParsableCommand {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "GenerateNarrative")

    static let configuration = CommandConfiguration(
        commandName: "generate-narrative",
        abstract: "Generate an LLM narrative for the latest institutional pulse."
    )

    @Option(name: .long, help: "Path to the IJS corpus directory (overrides .quality-gate.yml)")
    var corpusPath: String?

    @Option(name: .long, help: "Pulse label to narrate (default: latest)")
    var label: String?

    @Option(name: .long, help: "Claude model ID for narrative generation")
    var model: String = "claude-sonnet-4-6"

    @Option(name: .long, help: "Narrative engine chain: auto | claude | on-device | preserved")
    var provider: ProviderChoice = .auto

    @Flag(name: .long, inversion: .prefixedNo, help: "Also emit a per-project narrative document for every project (on-device, when available)")
    var perProject: Bool = true

    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    func run() async throws {
        var configuration: Configuration
        do {
            configuration = try Configuration.load(from: config)
        } catch {
            Self.logger.warning("Failed to load configuration from \(config, privacy: .public): \(error.localizedDescription, privacy: .public)")
            configuration = Configuration()
        }

        let effectivePath = corpusPath ?? configuration.consistency.corpusPath
        guard let effectivePath else {
            print("[ijs] Error: No corpus path. Use --corpus-path or set consistency.corpusPath.")
            throw ExitCode(1)
        }

        let reader = CorpusReader(corpusPath: effectivePath)
        let allLabels = reader.listAvailableLabels()

        let targetLabel: String
        if let specified = label {
            targetLabel = specified
        } else {
            guard let latest = allLabels.last else {
                print("[ijs] Error: No pulses found in corpus")
                throw ExitCode(1)
            }
            targetLabel = latest
        }

        guard let pulse = reader.loadPulse(label: targetLabel) else {
            print("[ijs] Error: Could not load pulse for label '\(targetLabel)'")
            throw ExitCode(1)
        }

        var previousPulse: InstitutionalPulse?
        if let idx = allLabels.firstIndex(of: targetLabel), idx > 0 {
            previousPulse = reader.loadPulse(label: allLabels[idx - 1])
        }

        if verbose {
            print("[ijs] Target pulse: \(targetLabel)")
            if let prev = previousPulse {
                print("[ijs] Previous pulse: \(prev.label ?? prev.weekLabel)")
            }
        }

        // Load per-project work-logs so the narrative can attribute metric
        // movements to the work that produced them. Best-effort per project.
        let workTransport = DirectCorpusTransport()
        var workLogsByProject: [String: [WorkEvent]] = [:]
        for project in pulse.projects {
            let projectCorpus = CorpusPath(basePath: effectivePath, projectID: project)
            do {
                let events = try await workTransport.readWorkLog(from: projectCorpus)
                if !events.isEmpty { workLogsByProject[project] = events }
            } catch {
                Self.logger.warning("Skipping work-log for \(project, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let input = NarrativeInput(pulse: pulse, previousPulse: previousPulse, workLogsByProject: workLogsByProject)

        // Assemble the durability chain for the requested provider selection.
        let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        let onDevice = Self.makeOnDeviceGenerator()
        let chain = Self.buildChain(provider: provider, apiKey: apiKey, model: model, onDevice: onDevice)

        if chain.providers.isEmpty {
            print("[ijs] Error: No narrative provider is available for --provider \(provider.rawValue).")
            if provider == .onDevice { print("[ijs]   On-device Foundation Models requires Apple Silicon + macOS 26+ with Apple Intelligence enabled.") }
            throw ExitCode(1)
        }

        print("[ijs] Generating narrative (provider chain: \(chain.providers.map { $0.source.rawValue }.joined(separator: " → ")))...") // logging: CLI user-facing

        guard let result = await chain.narrate(input) else {
            print("[ijs] Error: Every provider in the chain failed to produce a narrative.")
            throw ExitCode(1)
        }

        print("[ijs] Narrative produced by: \(result.source.rawValue)") // logging: CLI user-facing

        // Write the portfolio narrative with provenance frontmatter.
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let frontmatter = """
            ---
            label: \(targetLabel)
            generatedAt: \(isoFormatter.string(from: Date()))
            model: \(result.source == .claude ? model : result.source.rawValue)
            source: \(result.source.rawValue)
            templateVersion: 1.2.0
            ---

            """
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")

        let fullNarrative = frontmatter + result.text
        let narrativeDir = "\(effectivePath)/pulse/\(targetLabel)" // SAFETY: effectivePath from config, targetLabel from pulse model
        let narrativePath = "\(narrativeDir)/NARRATIVE_\(targetLabel).md"

        let persistence = NarrativePersistence()
        try persistence.writePortfolio(fullNarrative, to: narrativePath)

        let updatedPulse = pulse.withNarrative(result.text, source: result.source)
        let writer = DirectCorpusTransport()
        let corpusWritePath = CorpusPath(basePath: effectivePath, projectID: pulse.projects.first ?? "corpus")
        try await writer.writePulse(updatedPulse, to: corpusWritePath)

        print("[ijs] Narrative written: \(narrativePath)") // logging: CLI user-facing
        print("[ijs] Pulse JSON updated with narrative") // logging: CLI user-facing

        // Per-project narratives, as a rule: generated on-device (free, local) for
        // every project. Skipped silently when the on-device model is unavailable.
        if perProject, let onDevice, onDevice.isAvailable {
            let fm = FoundationModelsNarrativeProvider(generator: onDevice)
            do {
                let leaves = try await fm.mapProjects(input)
                let written = try persistence.writePerProject(leaves, pulseDir: narrativeDir)
                print("[ijs] Wrote \(written.count) per-project narratives to \(narrativeDir)/projects/") // logging: CLI user-facing
            } catch {
                Self.logger.warning("Per-project narratives skipped: \(error.localizedDescription, privacy: .public)")
                print("[ijs] Per-project narratives skipped (\(error.localizedDescription))") // logging: CLI user-facing
            }
        } else if perProject, verbose {
            print("[ijs] Per-project narratives skipped: on-device model unavailable")
        }
    }

    // MARK: - Chain assembly

    private static func buildChain(
        provider: ProviderChoice,
        apiKey: String?,
        model: String,
        onDevice: (any OnDeviceNarrativeGenerator)?
    ) -> NarrativeChain {
        var providers: [any NarrativeProvider] = []
        switch provider {
        case .auto:
            providers.append(AnthropicNarrativeProvider(apiKey: apiKey, model: model))
            if let onDevice { providers.append(FoundationModelsNarrativeProvider(generator: onDevice)) }
            providers.append(PreservedNarrativeProvider())
        case .claude:
            providers.append(AnthropicNarrativeProvider(apiKey: apiKey, model: model))
        case .onDevice:
            if let onDevice { providers.append(FoundationModelsNarrativeProvider(generator: onDevice)) }
        case .preserved:
            providers.append(PreservedNarrativeProvider())
        }
        return NarrativeChain(providers: providers)
    }

    private static func makeOnDeviceGenerator() -> (any OnDeviceNarrativeGenerator)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            return SystemLanguageModelGenerator()
        }
        #endif
        return nil
    }
}
