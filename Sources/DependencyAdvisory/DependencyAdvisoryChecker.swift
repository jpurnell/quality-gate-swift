import Foundation
import QualityGateCore

/// Reports a pinned dependency version that a published advisory says is vulnerable.
///
/// ## An advisory is a dated fact
///
/// The verdict does not depend on whether a server answered. The advisories are read from a
/// **snapshot** — a file holding the whole OSV `SwiftURL` export as of one day — and *this
/// lockfile against that file* is a pure function of the two. So this checker is hermetic and
/// may fail a build; the same tree gives the same answer on any machine, on any day, offline.
///
/// What a snapshot cannot do is be current. Two satellites say so, and neither can fail a build
/// by default: ``AdvisoryFreshnessChecker`` reports the snapshot's age, and
/// ``AdvisoryDriftChecker`` asks live OSV what the snapshot lacks.
///
/// ## Which snapshot
///
/// The gate ships one; a repository may commit its own at
/// `.quality-gate/advisories/swifturl.json`. Whichever was fetched later is used, and the
/// coverage note names it and its date. Every finding ends with the date its data is from.
///
/// ## Rules
///
/// | Rule ID | What it flags | Severity |
/// |---|---|---|
/// | `dep-advisory.vulnerable-pin` | Pinned version inside an affected range | error for CRITICAL and HIGH; warning for MODERATE, LOW and unlabelled |
/// | `dep-advisory.vulnerable-pin-by-name` | The same, where the advisory names the package without a URL | as above |
/// | `dep-advisory.unevaluable` | An advisory names the package and the pin or range cannot be compared | warning |
/// | `dep-advisory.no-snapshot` | Third-party pins and no usable snapshot | warning |
/// | `dep-advisory.snapshot-corrupt` | A snapshot that is not what its header says | error |
/// | `dep-advisory.acknowledgement-expired` | An acknowledgement whose `until` the snapshot has reached | warning |
/// | `dep-advisory.acknowledgement-unused` | An acknowledgement no finding matches | warning |
/// | `dep-advisory.coverage` | What was examined, against which snapshot | note |
///
/// ## What it cannot see
///
/// Whether the vulnerable code is reached; a vulnerability nobody has reported (the export is
/// 64 records for the whole ecosystem); anything not in a lockfile; what a consumer of a library
/// will resolve. It reports known-vulnerable pins, which is a much smaller set than vulnerable.
///
/// ## Usage
///
/// ```swift
/// import QualityGateCore
///
/// let result = try await DependencyAdvisoryChecker().check(configuration: Configuration())
/// ```
public struct DependencyAdvisoryChecker: QualityChecker, Sendable {

    /// Unique identifier for this checker.
    public let id = "dependency-advisory"

    /// Human-readable name for display.
    public let name = "Dependency Advisory Checker"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Pinned dependency versions a published security advisory (OSV / GitHub Advisory Database) says are vulnerable, matched offline against a dated snapshot"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.safetySecurity

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Reads lockfiles and a snapshot; runs nothing.
    public let executesProjectCode = false

    /// A function of the lockfiles, the configuration and the snapshot — no clock, no network.
    ///
    /// The bundled snapshot is part of the gate binary, so a gate upgrade can turn a
    /// byte-identical commit from green to red. That is the same event as the gate gaining a
    /// rule: the commit did not change, what is known about it did, and a rerun under the old
    /// binary reproduces the old verdict.
    public var hermeticity: Hermeticity { .hermetic }

    let environment: AdvisoryEnvironment

    /// Creates the checker.
    public init() {
        self.init(environment: .live)
    }

    init(environment: AdvisoryEnvironment) {
        self.environment = environment
    }

    /// Checks every `Package.resolved` under the project root against the newer snapshot.
    ///
    /// - Parameter configuration: Supplies the project root and the `dependencyAudit` block.
    /// - Returns: The findings and a coverage note, or `.skipped` when there is no lockfile.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now
        let root = configuration.resolvedProjectRoot
        let discovery = LockfileDiscovery.discover(under: root)

        guard !discovery.lockfiles.isEmpty || !discovery.unreadable.isEmpty else {
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No Package.resolved was found under the project root, so there are no pins to "
                            + "check against advisories.",
                        ruleId: AdvisoryRule.coverage),
                ],
                duration: ContinuousClock.now - start)
        }

        let outcome = AdvisoryAudit.run(
            lockfiles: discovery.lockfiles,
            unreadable: discovery.unreadable,
            bundled: environment.bundled(),
            committed: AdvisorySnapshotStore.committed(
                projectRoot: root, relativePath: configuration.dependencyAudit.advisorySnapshotPath),
            configuration: configuration.dependencyAudit)

        return CheckResult(
            checkerId: id,
            status: outcome.status,
            diagnostics: outcome.diagnostics,
            overrides: outcome.overrides,
            duration: ContinuousClock.now - start)
    }
}
