import ArgumentParser
import Foundation
import QualityGateCore

/// `quality-gate re-verify` — the re-verify queue, L12's interaction
/// surface (Phase 3a §7, solo mode).
///
/// Lists the baseline debts past expiry and takes the two conscious
/// decisions the lifecycle allows: `--re-affirm` (re-dated, attributed to
/// the person extending it) or `--retire` (the record goes; a still-present
/// finding returns to the gate on the next run). With no action flags it
/// prints the queue. Nothing is silent, everything ages.
struct ReVerify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "re-verify",
        abstract: "Work the queue of expired baseline debts — re-affirm consciously or retire."
    )

    @Option(name: .customLong("re-affirm"), parsing: .upToNextOption,
            help: "Content hashes (from the queue listing) to re-affirm, or 'all'")
    var reAffirm: [String] = []

    @Option(name: .long, parsing: .upToNextOption,
            help: "Content hashes to retire, or 'all'")
    var retire: [String] = []

    @Option(name: .customLong("decay-days"), help: "New decay window for re-affirmed debts")
    var decayDays: Int = 180

    func run() throws {
        let path = ".quality-gate-baseline.json"
        let ledger = try BaselineLedger.load(from: path)
        let now = Date()
        let queue = ledger.reVerifyQueue(now: now)

        guard !reAffirm.isEmpty || !retire.isEmpty else {
            guard !queue.isEmpty else {
                print("Re-verify queue is empty — no baseline debts are past expiry.")
                return
            }
            print("Re-verify queue (\(queue.count) debt(s) past expiry):\n")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC") ?? .current
            for record in queue {
                let location = record.filePath ?? "(file unknown)"
                print("  \(record.contentHash.prefix(12))  \(record.ruleId)")
                print("      \(location) — expired \(formatter.string(from: record.expiresAt))")
            }
            print("""

            Decide consciously:
              quality-gate re-verify --re-affirm <hash-prefix ...|all> [--decay-days \(decayDays)]
              quality-gate re-verify --retire <hash-prefix ...|all>
            """)
            return
        }

        let person = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
        var updated = ledger

        if !retire.isEmpty {
            let hashes = Self.resolve(selectors: retire, in: queue)
            updated = updated.retiring(contentHashes: hashes)
            print("Retired \(hashes.count) debt(s) — still-present findings gate on the next run.")
        }
        if !reAffirm.isEmpty {
            let hashes = Self.resolve(selectors: reAffirm, in: updated.reVerifyQueue(now: now))
            updated = updated.reAffirming(
                contentHashes: hashes, decayDays: decayDays, now: now, attributedTo: person)
            print("Re-affirmed \(hashes.count) debt(s) for \(decayDays) day(s), attributed to \(person).")
        }

        try updated.save(to: path)
        print("Ledger saved — commit \(path) to record the decision.")
    }

    /// Expands 'all' and hash prefixes against the queue's records.
    static func resolve(selectors: [String], in queue: [BaselineRecord]) -> Set<String> {
        if selectors.contains("all") {
            return Set(queue.map(\.contentHash))
        }
        var hashes: Set<String> = []
        for selector in selectors {
            for record in queue where record.contentHash.hasPrefix(selector) {
                hashes.insert(record.contentHash)
            }
        }
        return hashes
    }
}
