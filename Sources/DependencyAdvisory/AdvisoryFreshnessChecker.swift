import Foundation
import QualityGateCore

/// Says when `dependency-advisory` is running on old information.
///
/// The advisory check is deterministic because it never reads the clock — which means a commit
/// can be green and vulnerable for as long as the snapshot is stale. This checker is the other
/// half: it compares the snapshot's `fetched` date with today, and reports when the gap exceeds
/// `dependencyAudit.advisorySnapshotMaxAgeDays` (14 by default).
///
/// It is `Hermeticity.temporal`. Its finding depends on the calendar, not on the commit, so by
/// default it is reported as a note and cannot fail a build; `--include-nonhermetic` lets it.
/// That is the reason the hermeticity contract exists, not an exception to it.
///
/// ## Rules
///
/// | Rule ID | What it reports | Severity |
/// |---|---|---|
/// | `dep-advisory.snapshot-stale` | Snapshot older than the maximum, and how many pins that leaves checked only against old data | note; error under `--include-nonhermetic` |
/// | `dep-advisory.snapshot-age` | The snapshot's age, when within the maximum | note |
public struct AdvisoryFreshnessChecker: QualityChecker, Sendable {

    /// Unique identifier for this checker.
    public let id = "dependency-advisory-freshness"

    /// Human-readable name for display.
    public let name = "Dependency Advisory Freshness"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Advisory snapshot older than its stated maximum age — the pins were checked only against advisories known on that date (never gates by default)"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.safetySecurity

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Reads lockfiles, a snapshot and the clock; runs nothing.
    public let executesProjectCode = false

    /// Depends on today's date, so it is clamped to notes unless the caller asks otherwise.
    public var hermeticity: Hermeticity { .temporal }

    let environment: AdvisoryEnvironment

    /// Creates the checker.
    public init() {
        self.init(environment: .live)
    }

    init(environment: AdvisoryEnvironment) {
        self.environment = environment
    }

    /// Compares the snapshot's date with today's.
    ///
    /// - Parameter configuration: Supplies the project root and the maximum age.
    /// - Returns: A stale finding, an age note, or `.skipped` when there is nothing to date.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now
        let root = configuration.resolvedProjectRoot
        let lockfiles = LockfileDiscovery.discover(under: root).lockfiles
        let pins = lockfiles.reduce(0) { $0 + $1.pins.count }

        guard !lockfiles.isEmpty else {
            return skipped(
                "No Package.resolved was found under the project root, so no advisory snapshot was consulted.",
                since: start)
        }
        guard let chosen = environment.snapshot(projectRoot: root, configuration: configuration.dependencyAudit),
              let fetched = chosen.snapshot.fetchedDate else {
            return skipped(
                "No usable advisory snapshot, so there is no age to report; `dependency-advisory` reports the "
                    + "\(AdvisoryAudit.plural(pins, "pin")) that were not checked.",
                since: start)
        }

        let today = AdvisoryDate(utcDateOf: environment.now())
        let age = max(0, today.dayNumber - fetched.dayNumber)
        let maximum = configuration.dependencyAudit.advisorySnapshotMaxAgeDays
        let dated = "The advisory snapshot (\(chosen.origin.rawValue)) was fetched \(fetched.text), "
            + "\(AdvisoryAudit.plural(age, "day")) before \(today.text)"

        guard age > maximum else {
            return CheckResult(
                checkerId: id, status: .passed,
                diagnostics: [
                    Diagnostic(
                        severity: .note, message: "\(dated) (maximum \(maximum)).", ruleId: AdvisoryRule.snapshotAge),
                ],
                duration: ContinuousClock.now - start)
        }
        // An error here, which the runner's clamp reports as a note unless `--include-nonhermetic`.
        return CheckResult(
            checkerId: id, status: .failed,
            diagnostics: [
                Diagnostic(
                    severity: .error,
                    message: "\(dated); the maximum is \(maximum). \(AdvisoryAudit.plural(pins, "pin")) in "
                        + "\(AdvisoryAudit.plural(lockfiles.count, "lockfile")) were checked only against advisories "
                        + "known on \(fetched.text) — nothing published since has been checked. Run "
                        + "`quality-gate advisories refresh`, or upgrade the gate for a newer bundled snapshot.",
                    ruleId: AdvisoryRule.snapshotStale),
            ],
            duration: ContinuousClock.now - start)
    }

    private func skipped(_ message: String, since start: ContinuousClock.Instant) -> CheckResult {
        CheckResult(
            checkerId: id, status: .skipped,
            diagnostics: [Diagnostic(severity: .note, message: message, ruleId: AdvisoryRule.snapshotAge)],
            duration: ContinuousClock.now - start)
    }
}
