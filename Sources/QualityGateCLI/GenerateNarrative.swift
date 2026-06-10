import ArgumentParser
import Foundation
import os
import QualityGateCore
import IJSSensor
import IJSAggregator
import IJSDashboardCore

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

    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    func run() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
              !apiKey.isEmpty else {
            print("[ijs] Error: ANTHROPIC_API_KEY environment variable not set")
            throw ExitCode(1)
        }

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

        let systemPrompt = Self.buildSystemPrompt()
        let userPrompt = Self.buildUserPrompt(pulse: pulse, previousPulse: previousPulse)

        if verbose {
            print("[ijs] Prompt size: \(userPrompt.utf8.count) bytes")
        }

        print("[ijs] Calling \(model) for narrative generation...")

        let narrativeBody = try await Self.callAnthropic(
            system: systemPrompt,
            userMessage: userPrompt,
            model: model,
            apiKey: apiKey
        )

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let frontmatter = """
            ---
            label: \(targetLabel)
            generatedAt: \(isoFormatter.string(from: Date()))
            model: \(model)
            templateVersion: 1.1.0
            ---

            """
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")

        let fullNarrative = frontmatter + narrativeBody

        let narrativeDir = "\(effectivePath)/pulse/\(targetLabel)" // SAFETY: effectivePath from config, targetLabel from pulse model
        let narrativePath = "\(narrativeDir)/NARRATIVE_\(targetLabel).md"

        // SAFETY: narrativeDir built from config-supplied corpus path + pulse-model label
        try FileManager.default.createDirectory(atPath: narrativeDir, withIntermediateDirectories: true)
        try fullNarrative.write(toFile: narrativePath, atomically: true, encoding: .utf8)

        let updatedPulse = pulse.withNarrative(narrativeBody)
        let writer = TelemetryWriter()
        let corpusPath = CorpusPath(basePath: effectivePath, projectID: pulse.projects.first ?? "corpus")
        try await writer.writePulse(updatedPulse, to: corpusPath)

        print("[ijs] Narrative written: \(narrativePath)") // logging: CLI user-facing output
        print("[ijs] Pulse JSON updated with narrative") // logging: CLI user-facing output
        print("[ijs]   Model: \(model)") // logging: CLI user-facing output
        print("[ijs]   Size: \(fullNarrative.utf8.count) bytes") // logging: CLI user-facing output
    }

    private static func decimal(_ value: Double, _ places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }

    // MARK: - Prompt Construction

    static func buildSystemPrompt() -> String {
        """
        You are an institutional quality analyst generating a daily pulse narrative \
        for a Swift development portfolio of ~50 projects. The portfolio owner is a \
        senior developer who manages all these projects personally.

        Your narrative should:
        - Open with a 1–2 sentence summary of the CURRENT STATE from the Current Snapshot section
        - Clearly distinguish between current state (snapshot) and historical trends (window). \
        The reader cares most about "where are we now" and then "how did we get here."
        - Analyze patterns rather than restating numbers the reader can already see in the dashboard
        - Cross-reference related projects (e.g. a parent app and its library dependencies)
        - Distinguish real signals from statistical noise — always note sample sizes
        - Be honest about what the data doesn't support (e.g. "insufficient" trajectories)
        - End with 3–5 forward guidance items ordered by priority and actionability

        Style rules:
        - Use markdown with ## headers and | tables where helpful
        - Be direct and analytical, not promotional
        - Numbers need context: "0.983" means nothing without "up from 0.972" or "highest in portfolio"
        - When a metric rests on few data points, say so explicitly
        - Total length: 800–1200 words
        - Do NOT include YAML frontmatter — it is added by the caller
        - Do NOT open with "# " (h1) — use "## " (h2) for the top heading

        Scoring context:
        - Weighted quality scores range 0.0–1.0; safety/correctness checkers carry higher weight \
        than documentation/style checkers
        - Trajectories use OLS regression on daily weighted scores; r² indicates fit quality
        - "Insufficient" trajectory = fewer than 3 deduplicated full-suite runs — no trend computable
        - Anomalies are gated by statistical maturity: "confirmed" (baseline n≥30), \
        "directional" (15≤n<30), "unreliable" (n<15)
        - Partial debug runs (single-checker invocations) and same-day duplicates are already \
        filtered out before scoring
        """
    }

    static func buildUserPrompt(
        pulse: InstitutionalPulse,
        previousPulse: InstitutionalPulse?
    ) -> String {
        let label = pulse.label ?? pulse.weekLabel
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = TimeZone(identifier: "UTC")
        dateFmt.locale = Locale(identifier: "en_US_POSIX")

        var sections: [String] = []

        sections.append("""
            ## Pulse Data: \(label)
            Window: \(dateFmt.string(from: pulse.windowStart)) to \(dateFmt.string(from: pulse.windowEnd))
            Projects in corpus: \(pulse.projects.count)
            Generated: \(dateFmt.string(from: pulse.generatedAt))
            """)

        // Current snapshot — latest run per project
        if let snap = pulse.currentSnapshot {
            let failing = snap.projects.filter { !$0.allPassed }
            var section = """
                ## Current Snapshot (latest run per project)
                This is the CURRENT state — not historical. Use this to answer "how are things right now?"
                - Projects: \(snap.totalProjects) total, \(snap.passingProjects) passing, \(snap.failingProjects) failing
                - Overrides: \(snap.totalOverrides)
                - Compliance annotations: \(snap.totalComplianceCount)
                """
            if failing.isEmpty {
                section += "\n- All projects are currently passing all checkers."
            } else {
                section += "\n- Currently failing projects:"
                for p in failing.sorted(by: { $0.projectID < $1.projectID }) {
                    section += "\n  - \(p.projectID): \(p.failedCheckers.joined(separator: ", "))"
                }
            }
            if !snap.failingCheckers.isEmpty {
                let top = snap.failingCheckers.sorted { $0.value > $1.value }.prefix(5)
                section += "\n- Top failing checkers (current): \(top.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))"
            }
            sections.append(section)
        }

        // Window statistics (30-day aggregate — includes historical runs)
        let s = pulse.statistics
        var stats = """
            ## Window Statistics (30-day aggregate)
            These numbers include ALL runs in the window, including resolved incidents. Do NOT present these as current state.
            - Gate runs: \(s.totalGateRuns)
            - Passed: \(s.passedRuns) (\(decimal(s.passRate, 1))%)
            - Failed: \(s.failedRuns)
            - Overrides: \(s.totalOverrides)
            - Calibrations: \(s.totalCalibrations)
            """
        if let prev = previousPulse {
            let ps = prev.statistics
            stats += "\n\nPrevious pulse (\(prev.label ?? prev.weekLabel)):"
            stats += "\n- Gate runs: \(ps.totalGateRuns) → \(s.totalGateRuns)"
            stats += "\n- Pass rate: \(decimal(ps.passRate, 1))% → \(decimal(s.passRate, 1))%"
            stats += "\n- Overrides: \(ps.totalOverrides) → \(s.totalOverrides)"
        }
        sections.append(stats)

        // Tier distribution
        if let tiers = pulse.projectTiers {
            let grouped = Dictionary(grouping: tiers, by: { $0.value })
            var section = "## Project Tier Distribution"
            for tier in [ProjectTier.active, .baseline, .firstContact, .atRisk, .dormant] {
                let names = (grouped[tier] ?? []).map(\.key).sorted()
                section += "\n- \(tier.rawValue) (\(names.count)): \(names.joined(separator: ", "))"
            }
            sections.append(section)
        }

        // Weighted scores
        if let scores = s.weightedScores {
            let sorted = scores.sorted { $0.value > $1.value }
            var section = "## Weighted Quality Scores\n| Project | Score | Tier |\n|---------|-------|------|"
            for (project, score) in sorted {
                let tier = pulse.projectTiers?[project]?.rawValue ?? "–"
                section += "\n| \(project) | \(decimal(score, 3)) | \(tier) |"
            }

            let vals = sorted.map(\.value)
            let count = vals.count
            if count > 0 { // fp-safety: guarded by count check
                let mean = vals.reduce(0, +) / Double(count)
                let median: Double
                if count % 2 == 0 {
                    let mid = count / 2
                    median = (vals[mid - 1] + vals[mid]) / 2.0
                } else {
                    median = vals[count / 2]
                }
                section += "\n\nMean: \(decimal(mean, 3)), Median: \(decimal(median, 3)), Scored projects: \(count)"
            }

            if let prevScores = previousPulse?.statistics.weightedScores {
                let prevVals = Array(prevScores.values)
                let currVals = Array(scores.values)
                if !prevVals.isEmpty && !currVals.isEmpty { // fp-safety: guarded
                    let prevMean = prevVals.reduce(0, +) / Double(prevVals.count)
                    let currMean = currVals.reduce(0, +) / Double(currVals.count)
                    section += "\nPrevious mean: \(decimal(prevMean, 3)) → Current: \(decimal(currMean, 3))"
                }
            }
            sections.append(section)
        }

        // Trajectories
        if let trajectories = pulse.projectTrajectories {
            let byDir = Dictionary(grouping: trajectories, by: { $0.direction })
            var section = "## Trajectories"

            for dir in [TrajectoryDirection.improving, .stable, .declining] {
                let projs = byDir[dir] ?? []
                if projs.isEmpty { continue }
                section += "\n\n### \(dir.rawValue.capitalized) (\(projs.count))"
                for t in projs.sorted(by: { $0.projectID < $1.projectID }) {
                    section += "\n- \(t.projectID): slope=\(decimal(t.slope, 4)), "
                    section += "r²=\(decimal(t.rSquared, 2)), n=\(t.sampleSize)"
                    if t.inflectionDetected, let recent = t.recentSlope {
                        section += " [inflection, recent slope=\(decimal(recent, 4))]"
                    }
                }
            }

            let insufficient = byDir[.insufficient] ?? []
            if !insufficient.isEmpty {
                section += "\n\nInsufficient data (\(insufficient.count)): "
                section += insufficient.map(\.projectID).sorted().joined(separator: ", ")
            }
            sections.append(section)
        }

        // Top failing checkers
        if !s.failuresByChecker.isEmpty {
            let top = s.failuresByChecker.sorted { $0.value > $1.value }.prefix(10)
            var section = "## Top Failing Checkers"
            for (checker, count) in top {
                section += "\n- \(checker): \(count)"
            }
            sections.append(section)
        }

        // Anomalies
        if let gated = s.gatedAnomalies, !gated.isEmpty {
            var section = "## Gated Anomalies (\(gated.count))"
            for g in gated {
                let a = g.anomaly
                section += "\n- [\(g.gatedSeverity.rawValue)/\(g.actionability.rawValue)] "
                section += "\(a.metric) in \(a.scope): "
                section += "observed=\(decimal(a.observedValue, 3)), "
                section += "expected=\(decimal(a.expectedValue, 3)), "
                section += "z=\(decimal(a.zScore, 2)), "
                section += "baseline=\(a.baselineValidity.rawValue)"
            }
            sections.append(section)
        } else if !s.anomalies.isEmpty {
            var section = "## Anomalies (\(s.anomalies.count))"
            for a in s.anomalies {
                section += "\n- \(a.metric) in \(a.scope): z=\(decimal(a.zScore, 2)), "
                section += "\(a.direction.rawValue), baseline=\(a.baselineValidity.rawValue)"
            }
            sections.append(section)
        }

        // Group summaries
        if let groups = pulse.groupSnapshots, !groups.isEmpty {
            var section = "## Group Summaries"
            for (groupID, snaps) in groups.sorted(by: { $0.key < $1.key }) {
                let runs = snaps.reduce(0) { $0 + $1.gateRuns }
                let passed = snaps.reduce(0) { $0 + $1.passedRuns }
                let failed = snaps.reduce(0) { $0 + $1.failedRuns }
                section += "\n- \(groupID): \(runs) runs (\(passed) passed, \(failed) failed), "
                section += "\(snaps.count) active days"
            }
            sections.append(section)
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Anthropic API

    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")

    private static func callAnthropic(
        system: String,
        userMessage: String,
        model: String,
        apiKey: String
    ) async throws -> String {
        guard let url = apiURL else {
            throw IJSError.configurationError(reason: "Invalid API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        let body = AnthropicRequest(
            model: model,
            maxTokens: 4096,
            system: system,
            messages: [AnthropicMessage(role: "user", content: userMessage)]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NarrativeError.invalidResponse
        }

        guard http.statusCode == 200 else {
            if let parsed = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
                throw NarrativeError.apiError(status: http.statusCode, message: parsed.error.message)
            }
            throw NarrativeError.httpError(status: http.statusCode)
        }

        let apiResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = apiResponse.content.first(where: { $0.type == "text" })?.text else {
            throw NarrativeError.emptyResponse
        }

        return text
    }
}

// MARK: - API Wire Types

private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [AnthropicMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct AnthropicMessage: Encodable {
    let role: String
    let content: String
}

private struct AnthropicResponse: Decodable {
    let content: [ContentBlock]
}

private struct ContentBlock: Decodable {
    let type: String
    let text: String?
}

private struct AnthropicErrorResponse: Decodable {
    let error: ErrorDetail
    struct ErrorDetail: Decodable {
        let message: String
    }
}

// MARK: - Errors

enum NarrativeError: LocalizedError {
    case invalidResponse
    case httpError(status: Int)
    case apiError(status: Int, message: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Anthropic API"
        case .httpError(let status):
            return "Anthropic API returned HTTP \(status)"
        case .apiError(let status, let message):
            return "Anthropic API error (\(status)): \(message)"
        case .emptyResponse:
            return "Anthropic API returned no text content"
        }
    }
}
