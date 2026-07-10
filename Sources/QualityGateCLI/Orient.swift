import ArgumentParser
import Foundation
#if canImport(os)
import os
#endif
import LegibilityAnalyzer
import QualityGateCore

/// `quality-gate orient <path>` — the zero-config onboarding map (Phase 1 §3).
///
/// One command, one minute, any Swift package: resolve the package, run the
/// legibility pipeline only, and print the reading order + composition map.
/// No corpus, no config required, and never a build — index-backed semantics
/// are opt-in (`--semantic`) and only reuse a store that already exists.
struct Orient: AsyncParsableCommand {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "Orient")

    static let configuration = CommandConfiguration(
        commandName: "orient",
        abstract: "Generate a reading order and composition map for any Swift package — zero config, read-only."
    )

    @Argument(help: "Path to the package root (default: current directory)")
    var path: String = "."

    @Option(name: .long, help: "Output format: md or json")
    var format: String = "md"

    @Option(name: .long, help: "Write ORIENT.md / orient.json into this directory instead of stdout")
    var output: String?

    @Flag(name: .long, help: "Use an existing index store for semantic fan-in (never builds one)")
    var semantic: Bool = false

    func run() async throws {
        guard let orientFormat = LegibilityAnalyzer.OrientFormat(rawValue: format) else {
            print("ERROR: --format must be 'md' or 'json'")
            throw ExitCode(1)
        }

        let target = URL(fileURLWithPath: path).standardizedFileURL
        let manifest = target.appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: manifest.path) else { // SAFETY: read-only existence check
            print("ERROR: no Package.swift at \(target.path) — orient works on Swift packages.")
            throw ExitCode(1)
        }
        guard FileManager.default.changeCurrentDirectoryPath(target.path) else {
            print("ERROR: cannot enter \(target.path)")
            throw ExitCode(1)
        }

        // Never compile someone's project to orient in it.
        setenv("QG_NO_INDEX_BUILD", "1", 1)

        // A repo with its own .quality-gate.yml is analyzed under its own
        // declared standard; anything else gets the contributor watermark.
        let hasOwnConfig = FileManager.default
            .fileExists(atPath: target.appendingPathComponent(ConfigResolver.repoConfigFileName).path)

        var effective: Configuration
        do {
            effective = try LayeredConfig.resolve(repoConfigPath: ConfigResolver.repoConfigFileName).configuration
        } catch {
            Self.logger.warning("orient: config resolution failed (\(error.localizedDescription, privacy: .public)) — using defaults")
            effective = Configuration()
        }
        effective.legibility.useIndexStore = semantic
        effective.legibility.emitReadingOrderArtifact = false

        let document = try await LegibilityAnalyzer().orientDocument(
            configuration: effective,
            packageName: target.lastPathComponent,
            watermarked: !hasOwnConfig,
            format: orientFormat
        )

        guard let output else {
            print(document)
            return
        }
        let outputDir = URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
        let fileName = orientFormat == .markdown ? "ORIENT.md" : "orient.json"
        let destination = outputDir.appendingPathComponent(fileName)
        // The read-only promise holds even for explicit --output: refuse to
        // drop artifacts inside a repo that isn't set up for them.
        if !hasOwnConfig, RunEnvironment.path(destination, isInside: target) {
            print("ERROR: refusing to write \(fileName) inside the analyzed repo — pass an --output outside it.")
            throw ExitCode(1)
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true) // SAFETY: user-requested output directory
        try document.write(to: destination, atomically: true, encoding: .utf8)
        print("Wrote \(destination.path)")
    }
}
