import ArgumentParser
import Foundation
import QualityGateCore
import IJSSensor
import IJSAggregator

struct TelemetryPush: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "telemetry-push",
        abstract: "Push quality gate results to the IJS corpus."
    )

    @Option(name: .long, help: "Path to JSON file containing quality gate results")
    var input: String?

    @Option(name: .long, help: "Path to the IJS corpus directory (overrides .quality-gate.yml)")
    var corpusPath: String?

    @Option(name: .long, help: "Project identifier (overrides .quality-gate.yml)")
    var projectID: String?

    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    func run() async throws {
        var configuration: Configuration
        do {
            configuration = try Configuration.load(from: config)
        } catch {
            configuration = Configuration()
        }

        let effectiveCorpusPath = corpusPath ?? configuration.consistency.corpusPath
        guard let effectiveCorpusPath else {
            print("[ijs] Error: No corpus path configured. Set consistency.corpusPath in .quality-gate.yml or use --corpus-path.")
            throw ExitCode(1)
        }

        let effectiveProjectID = projectID
            ?? configuration.consistency.projectID
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent

        let riskTier = RiskTier(rawValue: configuration.consistency.defaultRiskTier) ?? .operational
        let corpus = CorpusPath(basePath: effectiveCorpusPath, projectID: effectiveProjectID)
        let writer = TelemetryWriter()

        let metadata: CheckResultMetadata

        if let inputPath = input {
            guard FileManager.default.fileExists(atPath: inputPath) else { // SAFETY: CLI argument, validated before read
                print("[ijs] Error: Input file not found: \(inputPath)")
                throw ExitCode(1)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            metadata = try decoder.decode(CheckResultMetadata.self, from: data)
        } else {
            let isCI = ProcessInfo.processInfo.environment["CI"] != nil
            metadata = CheckResultMetadata(
                projectID: effectiveProjectID,
                timestamp: Date(),
                environment: isCI ? .ci : .local,
                decisionOwner: "local",
                results: [],
                overrides: [],
                riskTier: riskTier,
                ethicalFlags: [],
                consistencyScore: nil
            )
        }

        try await writer.write(metadata: metadata, calibrations: [], to: corpus)
        print("[ijs] Telemetry written to \(corpus.projectDirectory)")

        if verbose {
            print("[ijs] Project: \(effectiveProjectID)")
            print("[ijs] Corpus: \(effectiveCorpusPath)")
            print("[ijs] Timestamp: \(metadata.timestamp)")
            print("[ijs] Results: \(metadata.results.count) checker(s)")
        }
    }
}
