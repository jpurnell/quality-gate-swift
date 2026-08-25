import ArgumentParser
import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// `quality-gate adopt` — the decaying baseline's front door (Phase 4c §3).
///
/// Scans a legacy repo and records every existing error/warning as a
/// baseline judgment artifact: finding + content hash + recorded date +
/// expiry. The gate is green on day one; new findings gate immediately;
/// every recorded debt is visible and *comes due*. Sonar's "new code"
/// ergonomics, without the institutionalized suppression.
struct Adopt: AsyncParsableCommand {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "Adopt")

    static let configuration = CommandConfiguration(
        commandName: "adopt",
        abstract: "Record every existing finding as expiring baseline debt — green gate today, everything ages."
    )

    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    @Option(name: .customLong("decay-days"), help: "Days until each recorded debt comes due")
    var decayDays: Int = 180

    @Option(name: .customLong("checkers"), parsing: .upToNextOption, help: "Checker subset to adopt from (default: the standard set)")
    var checkers: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Checkers to exclude")
    var exclude: [String] = []

    func run() async throws {
        var configuration: Configuration
        do {
            configuration = try LayeredConfig.resolve(repoConfigPath: config).configuration
        } catch {
            Self.logger.warning("adopt: config resolution failed (\(error.localizedDescription, privacy: .public)) — using defaults")
            configuration = Configuration()
        }

        let registry = QualityGateCLI.checkerRegistry(configuration: configuration)
        let selected = CheckerSelection.resolve(
            requested: checkers,
            excluded: exclude,
            configuredEnabled: configuration.enabledCheckers,
            full: false,
            allIDs: registry.map(\.id))
        let checkersToRun = registry.filter { selected.contains($0.id) }
        guard !checkersToRun.isEmpty else {
            print("No checkers selected — nothing to adopt.")
            throw ExitCode(1)
        }

        print("Scanning with \(checkersToRun.count) checker(s) to record existing debt…")
        let runner = CheckerRunner()
        // `continueOnFailure: true`, so this outcome is never truncated.
        let outcome = await runner.run(
            checkers: checkersToRun,
            configuration: configuration,
            strict: false,
            continueOnFailure: true,
            cache: nil,
            gateHash: "",
            useCache: false,
            transform: { $0 },
            onError: { checkerID, error in
                Self.logger.error("adopt: checker '\(checkerID, privacy: .public)' threw: \(error.localizedDescription, privacy: .public)")
            }
        )

        let findings = outcome.results.flatMap(\.diagnostics).filter { $0.severity != .note }
        let recordedAt = Date()
        let ledger = BaselineLedger.adopt(
            findings: findings, recordedAt: recordedAt, decayDays: decayDays)

        let path = ".quality-gate-baseline.json"
        try ledger.save(to: path)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let expiry = dateFormatter.string(
            from: recordedAt.addingTimeInterval(Double(decayDays) * 86_400))

        print("""
        ✅ Adopted \(ledger.records.count) existing finding(s) as baseline debt.
           Ledger: \(path) — commit it; recorded debt is shared, not machine-local.
           Every debt expires \(expiry) (\(decayDays) days): fix it, or re-verify consciously.
           The gate is green from here; NEW findings gate immediately.
        """)
    }
}
