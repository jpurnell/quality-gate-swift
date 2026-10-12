import Foundation
import QualityGateCore

/// The rule ids the advisory checkers emit.
enum AdvisoryRule {
    /// A pinned version is inside a range a published advisory says is affected.
    static let vulnerablePin = "dep-advisory.vulnerable-pin"
    /// As above, where the advisory names the package without a URL.
    static let vulnerablePinByName = "dep-advisory.vulnerable-pin-by-name"
    /// An advisory names the package and the pin or the range cannot be compared.
    static let unevaluable = "dep-advisory.unevaluable"
    /// Third-party pins are present and no snapshot could be used.
    static let noSnapshot = "dep-advisory.no-snapshot"
    /// A snapshot file is not what its header says it is.
    static let snapshotCorrupt = "dep-advisory.snapshot-corrupt"
    /// An acknowledgement's `until` has been reached by the snapshot's date.
    static let acknowledgementExpired = "dep-advisory.acknowledgement-expired"
    /// An acknowledgement matches no finding.
    static let acknowledgementUnused = "dep-advisory.acknowledgement-unused"
    /// The denominators: what was examined, and against which snapshot.
    static let coverage = "dep-advisory.coverage"
    /// The snapshot is older than the configured maximum (`dependency-advisory-freshness`).
    static let snapshotStale = "dep-advisory.snapshot-stale"
    /// The snapshot's age, when it is within the maximum.
    static let snapshotAge = "dep-advisory.snapshot-age"
    /// Live OSV names an advisory for a pin that the snapshot does not hold (`dependency-advisory-drift`).
    static let unlisted = "dep-advisory.unlisted"
    /// What the live comparison covered.
    static let driftCoverage = "dep-advisory.drift-coverage"
}

/// How an advisory's severity becomes a finding's.
///
/// The label is GitHub's (`database_specific.severity`), which every record in the Swift export
/// carries. It is not recomputed from the CVSS vector: a quarter of the records are CVSS v4,
/// whose base score is a table lookup the gate would have to carry and keep right, to arrive at
/// a label it has already been given.
enum AdvisorySeverity {

    /// What a MODERATE advisory is reported at.
    ///
    /// **A warning on arrival; an error at the proposal's destination** (`AnAdvisoryIsADatedFact.md`
    /// §4.4, rollout step 5 — the first gate release after 2026-11-01, once the portfolio is at
    /// zero or acknowledged). CRITICAL and HIGH do not wait: `TheGateIsNotYetAggressive.md` puts
    /// them at error from the first day. This constant is the whole of the difference, so that
    /// raising it is one line and one test.
    static let moderate: Diagnostic.Severity = .warning

    /// The severity for a finding whose advisory carries `label`.
    static func severity(forLabel label: String?) -> Diagnostic.Severity {
        switch label {
        case "CRITICAL", "HIGH": return .error
        case "MODERATE": return moderate
        // LOW, an unrecognised label, or none recorded: reported, and not a reason to stop a build.
        default: return .warning
        }
    }
}
