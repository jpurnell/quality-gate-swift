import Foundation

/// What a checker's verdict depends on beyond the working tree.
///
/// A gate's verdict should be a function of the commit being checked. When it
/// is not — when a finding depends on the calendar or on a service being
/// reachable — three things go wrong: a byte-identical commit passes today and
/// fails later; corpus telemetry stops being comparable across runs, because a
/// verdict shift no longer means the code shifted; and an old commit's original
/// verdict can no longer be reproduced.
///
/// The remedy is not to delete such checks — staleness and upstream drift are
/// worth knowing about — but to strip their authority. A non-hermetic finding
/// still reports, at `.note`, and never blocks.
public enum Hermeticity: String, Sendable, Codable, CaseIterable {

    /// A pure function of the working tree. May fail the gate.
    ///
    /// The default, and the right answer for every AST-based auditor: given the
    /// same files, it returns the same result forever.
    case hermetic

    /// Depends on wall-clock time. May not fail the gate.
    ///
    /// Findings clamp to `.note` and the verdict clamps to `.passed`. A document
    /// that has gone stale is a maintenance signal, not evidence against the
    /// commit that happens to be in front of it.
    case temporal

    /// Depends on network or out-of-tree state. May not fail the gate.
    ///
    /// Clamped like ``temporal``; additionally, a checker that throws while
    /// reaching for unavailable state resolves to `.skipped` with the reason
    /// preserved, rather than to a failure.
    case external
}

extension QualityChecker {
    /// Defaults to ``Hermeticity/hermetic`` — the safe default.
    ///
    /// Mislabeling a temporal check as hermetic causes visible, diagnosable
    /// failures; mislabeling in the other direction would silently disarm a real
    /// gate. So the default is the one whose failure mode is loud.
    public var hermeticity: Hermeticity { .hermetic }
}

/// Strips gate authority from findings a checker cannot derive from the tree.
///
/// Applied by ``CheckerRunner`` after a checker runs and after overrides are
/// applied, so overrides still match on original severities, and so terminal
/// output, SARIF, and telemetry all observe the same clamped truth. This is the
/// same seam ``AdvisoryDowngrade`` occupies for `--advisory-all`.
public enum HermeticityClamp {

    /// Returns `result` with its severities and verdict clamped for `hermeticity`.
    ///
    /// Hermetic results pass through untouched. For `.temporal` and `.external`,
    /// every diagnostic drops to `.note` and a failing verdict becomes `.passed`
    /// — while message, location, rule id, and suggested fix survive intact, so
    /// the finding is fully reported and merely disarmed.
    ///
    /// `.skipped` is preserved in every case: nothing ran, and reporting a pass
    /// would be a lie in the opposite direction.
    ///
    /// - Parameters:
    ///   - result: The result as produced by the checker.
    ///   - hermeticity: The checker's declared dependency class.
    /// - Returns: The clamped result.
    public static func apply(to result: CheckResult, hermeticity: Hermeticity) -> CheckResult {
        guard hermeticity != .hermetic else { return result }

        return CheckResult(
            checkerId: result.checkerId,
            status: result.status == .skipped ? .skipped : .passed,
            diagnostics: result.diagnostics.map { diagnostic in
                Diagnostic(
                    severity: .note,
                    message: diagnostic.message,
                    filePath: diagnostic.filePath,
                    lineNumber: diagnostic.lineNumber,
                    columnNumber: diagnostic.columnNumber,
                    ruleId: diagnostic.ruleId,
                    suggestedFix: diagnostic.suggestedFix,
                    origin: diagnostic.origin)
            },
            overrides: result.overrides,
            complianceRecords: result.complianceRecords,
            duration: result.duration)
    }

    /// Builds the result for an `.external` checker that could not reach its state.
    ///
    /// Reports `.skipped` carrying the underlying reason, so the report can say
    /// *why* nothing ran instead of silently showing a green check.
    ///
    /// - Parameters:
    ///   - checkerId: The checker that could not run.
    ///   - reason: The underlying error description.
    /// - Returns: A skipped result carrying `reason` as a note.
    public static func unavailable(checkerId: String, reason: String) -> CheckResult {
        CheckResult(
            checkerId: checkerId,
            status: .skipped,
            diagnostics: [
                Diagnostic(
                    severity: .note,
                    message: "Skipped — external state unavailable: \(reason)",
                    ruleId: "hermeticity.external-unavailable")
            ],
            duration: .zero)
    }
}
