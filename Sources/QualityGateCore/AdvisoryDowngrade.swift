import Foundation

/// Trial mode's one honest transform (Phase 4 §3, `--advisory-all`).
///
/// Runs the whole gate as a *survey*: every error/warning becomes a note and
/// every failing verdict becomes passed, so a legacy codebase gets a complete
/// picture instead of a wall of failure — while each finding's message,
/// location, and rule survive untouched. Applied once, after checkers run and
/// before reporting, so terminal output, SARIF, and telemetry all see the
/// same downgraded truth. Telemetry marks such runs `gateMode: advisory` so
/// they never count as green gates.
public enum AdvisoryDowngrade {

    /// Returns the results with severities and verdicts downgraded.
    ///
    /// - Parameter results: The checker results as produced by the run.
    /// - Returns: The same results with every diagnostic at `.note` and every
    ///   failed/warning verdict at `.passed`; skipped checkers stay skipped
    ///   (nothing ran — passing them would be a lie in the other direction).
    public static func apply(to results: [CheckResult]) -> [CheckResult] {
        results.map { result in
            CheckResult(
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
    }
}
