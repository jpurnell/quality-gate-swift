import Foundation

/// Makes a result's status agree with the diagnostics it carries.
///
/// The summary counts **diagnostics** and `--strict` used to gate on **status**. The two
/// were computed independently, and each checker chose its own status: nineteen of them
/// computed it from errors alone, so a warning they emitted was printed, counted, and
/// invisible to `--strict`. `BioFeedbackKit-HRBLE` printed `0 error(s), 4 warning(s)`
/// under `--strict` and exited 0.
///
/// Reconciliation is the enforcement a per-checker convention never had. It is applied to
/// every result at the two points every result passes through — ``CheckerRunner`` and the
/// CLI's post-run consistency stage — so no checker has to remember it.
extension CheckResult {

    /// The rule id of the finding the gate adds when a checker reports `.warning` and
    /// carries no warning-severity diagnostic.
    public static let statusWithoutFindingRuleID = "gate.status-without-finding"

    /// This result with its status raised to what its diagnostics say.
    ///
    /// It **only ever raises**:
    ///
    /// | status | diagnostics | result |
    /// |---|---|---|
    /// | `.skipped` | any | unchanged |
    /// | `.failed` | any | unchanged |
    /// | `.passed` | an error | `.failed` |
    /// | `.passed` | a warning, no error | `.warning` |
    /// | `.warning` | an error | `.failed` |
    /// | `.warning` | no warning, no error | `.warning`, plus one `gate.status-without-finding` warning |
    /// | otherwise | | unchanged |
    ///
    /// Never lowering is deliberate. `safety` and `concurrency` fail on warnings without
    /// `--strict`; that is a severity policy those checkers chose, and loosening a default
    /// gate is a different change.
    ///
    /// The two error rows are the only ones that change a run without `--strict`: a result
    /// that carries an error fails, whatever status it reported. `1 error(s)` above
    /// `✅ PASSED` is the same disagreement as a counted warning that does not gate.
    ///
    /// The last row keeps the agreement two-way. A `.warning` status the count cannot
    /// see is the same disagreement in the other direction: the run fails under `--strict`
    /// while printing `0 warning(s)`. The synthesized finding makes that visible, and names
    /// the checker that owes a warning of its own.
    ///
    /// - Returns: A result whose status is consistent with its diagnostics. Idempotent.
    public func reconciled() -> CheckResult {
        switch status {
        case .skipped, .failed:
            return self
        case .passed:
            if errorCount > 0 { return replacing(status: .failed, diagnostics: diagnostics) }
            guard warningCount > 0 else { return self }
            return replacing(status: .warning, diagnostics: diagnostics)
        case .warning:
            if errorCount > 0 { return replacing(status: .failed, diagnostics: diagnostics) }
            guard warningCount == 0 else { return self }
            let synthesized = Diagnostic(
                severity: .warning,
                message: "[\(checkerId)] reported WARNING without a warning-severity finding",
                ruleId: Self.statusWithoutFindingRuleID
            )
            return replacing(status: .warning, diagnostics: diagnostics + [synthesized])
        }
    }

    /// Whether this result, on its own, fails the run.
    ///
    /// The one per-result predicate: the runner's early stop and ``RunTally`` both read it,
    /// so "does this fail under `--strict`" is written once. Meaningful over reconciled
    /// results, where a `.warning` status and a counted warning are the same fact.
    ///
    /// - Parameter strict: Whether warnings fail the run, as under `--strict`.
    /// - Returns: `true` for a failed result, and for a warned one under `strict`.
    public func failsRun(strict: Bool) -> Bool {
        status == .failed || (strict && status == .warning)
    }

    private func replacing(status: Status, diagnostics: [Diagnostic]) -> CheckResult {
        CheckResult(
            checkerId: checkerId,
            status: status,
            diagnostics: diagnostics,
            overrides: overrides,
            complianceRecords: complianceRecords,
            duration: duration
        )
    }
}
