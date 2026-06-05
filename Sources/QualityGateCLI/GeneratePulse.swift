import ArgumentParser // logging: CLI tool — print() is appropriate for user-facing output
import Foundation
import QualityGateCore
import IJSSensor
import IJSAggregator
import IJSRefiner
import IJSDashboardCore

struct GeneratePulse: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "generate-pulse",
        abstract: "Generate an Institutional Pulse from corpus telemetry."
    )

    @Option(name: .long, help: "Path to the IJS corpus directory (overrides .quality-gate.yml)")
    var corpusPath: String?

    @Option(name: .long, help: "Number of days to include in the pulse window (default: 30)")
    var windowDays: Int = 30

    @Option(name: .long, help: "Number of days of baseline data for anomaly detection (default: 90)")
    var lookbackDays: Int = 90

    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    @Flag(name: .long, help: "Use ISO week label (e.g. 2026-W22) instead of daily date label")
    var weekly: Bool = false

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    func run() async throws {
        var configuration: Configuration
        do {
            configuration = try Configuration.load(from: config)
        } catch { // logging: falling back to default configuration
            configuration = Configuration()
        }

        let effectiveCorpusPath = corpusPath ?? configuration.consistency.corpusPath
        guard let effectiveCorpusPath else {
            print("[ijs] Error: No corpus path configured. Set consistency.corpusPath in .quality-gate.yml or use --corpus-path.") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        let fm = FileManager.default
        let telemetryDir = "\(effectiveCorpusPath)/telemetry" // SAFETY: configured corpus path
        guard fm.fileExists(atPath: telemetryDir) else { // SAFETY: read-only check on configured path
            print("[ijs] Error: No telemetry directory found at \(telemetryDir)") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        let projectDirs = try fm.contentsOfDirectory(atPath: telemetryDir) // SAFETY: reads configured corpus
            .filter { name in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: "\(telemetryDir)/\(name)", isDirectory: &isDir) && isDir.boolValue // SAFETY: child of configured corpus
            }

        guard !projectDirs.isEmpty else {
            print("[ijs] Error: No projects found in corpus at \(effectiveCorpusPath)") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        let corpusPaths = projectDirs.map { CorpusPath(basePath: effectiveCorpusPath, projectID: $0) }

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let windowEnd = Date()
        guard let windowStart = calendar.date(byAdding: .day, value: -windowDays, to: windowEnd) else {
            print("[ijs] Error: Cannot compute window start date") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let dateLabel: String? = weekly ? nil : dateFormatter.string(from: windowEnd)

        let reader = CorpusReader(corpusPath: effectiveCorpusPath)
        let manifest: CorpusManifest
        do {
            manifest = try reader.loadManifest()
        } catch { // logging: manifest is optional; missing treated as all-active
            manifest = CorpusManifest()
        }

        print("[ijs] Generating pulse for \(projectDirs.count) project(s)") // logging: CLI user-facing output
        if verbose {
            print("[ijs] Projects: \(projectDirs.joined(separator: ", "))") // logging: CLI verbose progress output
            print("[ijs] Window: \(windowStart) – \(windowEnd)") // logging: CLI verbose progress output
            print("[ijs] Lookback: \(lookbackDays) days") // logging: CLI verbose progress output
        }

        let writer = TelemetryWriter()
        let refiner = PulseRefiner(writer: writer)

        let previousPulse = try await writer.readLatestPulse(from: corpusPaths[0])

        let pulse = try await refiner.refine(
            from: corpusPaths,
            windowStart: windowStart,
            windowEnd: windowEnd,
            previousPulse: previousPulse,
            lookbackDays: lookbackDays,
            manifest: manifest,
            label: dateLabel
        )

        try await writer.writePulse(pulse, to: corpusPaths[0])

        let effectiveLabel = pulse.label ?? pulse.weekLabel
        let pulsePath = corpusPaths[0].pulsePath(label: effectiveLabel) // SAFETY: effectiveLabel from pulse model
        print("[ijs] Pulse generated: \(effectiveLabel)") // logging: CLI user-facing output
        print("[ijs]   Gate runs: \(pulse.statistics.totalGateRuns) (\(pulse.statistics.passedRuns) passed, \(pulse.statistics.failedRuns) failed)") // logging: CLI user-facing output
        print("[ijs]   Overrides: \(pulse.statistics.totalOverrides)") // logging: CLI user-facing output
        print("[ijs]   Violation clusters: \(pulse.violationClusters.count)") // logging: CLI user-facing output
        print("[ijs]   Anomalies: \(pulse.statistics.anomalies.count)") // logging: CLI user-facing output
        print("[ijs]   Written to: \(pulsePath)") // logging: CLI user-facing output
    }
}
