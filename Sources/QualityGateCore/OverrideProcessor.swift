import Foundation

/// Applies per-rule severity overrides to checker results.
///
/// `OverrideProcessor` sits between checker output and the reporter. It
/// re-maps diagnostic severities (or suppresses them entirely) based on
/// override rules from `.quality-gate.yml`, then recomputes the
/// `CheckResult.status` to match the new diagnostic set.
///
/// ## Override Resolution
///
/// 1. **Exact match** — the diagnostic's `ruleId` matches an override key verbatim.
/// 2. **Wildcard match** — the override key ends with `.*` and the diagnostic's
///    `ruleId` starts with the prefix before the dot (e.g. `safety.*` matches
///    `safety.force-unwrap`).
/// 3. Exact matches take precedence over wildcards.
/// 4. Diagnostics with a nil `ruleId` are never overridden.
///
/// ## Status Recomputation
///
/// After applying overrides, the status is recomputed:
/// - Any `.error` diagnostic → `.failed`
/// - Any `.warning` (no errors) → `.warning`
/// - No diagnostics or all `.note` → `.passed`
/// - Original `.skipped` status is preserved unchanged.
public struct OverrideProcessor: Sendable {

    /// The configured per-rule severity overrides.
    private let overrides: [String: SeverityOverride]

    /// Path components that identify vendor/third-party code.
    /// Diagnostics in these paths are demoted to `.note`.
    private let vendorPaths: [String]

    /// Creates a new override processor.
    ///
    /// - Parameters:
    ///   - overrides: A dictionary mapping rule IDs (or wildcard
    ///     patterns like `"safety.*"`) to their desired severity level.
    ///   - vendorPaths: Path prefixes for vendor code whose diagnostics
    ///     should be demoted to notes.
    public init(
        overrides: [String: SeverityOverride],
        vendorPaths: [String] = []
    ) {
        self.overrides = overrides
        self.vendorPaths = vendorPaths
    }

    /// Applies overrides to a check result, returning a new result with
    /// adjusted diagnostics and recomputed status.
    ///
    /// - Parameter result: The original check result from a checker.
    /// - Returns: A new `CheckResult` with overrides applied.
    public func apply(to result: CheckResult) -> CheckResult {
        guard !overrides.isEmpty || !vendorPaths.isEmpty else { return result }

        // Skipped results pass through unchanged.
        guard result.status != .skipped else { return result }

        let processedDiagnostics = result.diagnostics.compactMap { diagnostic -> Diagnostic? in
            // Rule-based overrides first.
            if let ruleId = diagnostic.ruleId, let override = resolveOverride(for: ruleId) {
                switch override {
                case .off:
                    return nil
                case .error:
                    return withSeverity(.error, for: diagnostic)
                case .warning:
                    return withSeverity(.warning, for: diagnostic)
                case .info:
                    return withSeverity(.note, for: diagnostic)
                }
            }

            // Vendor path demotion: demote warnings/errors to notes.
            if diagnostic.severity != .note,
               let filePath = diagnostic.filePath,
               isVendorPath(filePath) {
                return withSeverity(.note, for: diagnostic)
            }

            return diagnostic
        }

        let newStatus = recomputeStatus(from: processedDiagnostics)

        return CheckResult(
            checkerId: result.checkerId,
            status: newStatus,
            diagnostics: processedDiagnostics,
            overrides: result.overrides,
            duration: result.duration
        )
    }

    // MARK: - Private Helpers

    /// Returns true if the file path falls under any configured vendor path.
    private func isVendorPath(_ filePath: String) -> Bool {
        vendorPaths.contains { vendor in
            filePath.contains("/\(vendor)/")
        }
    }

    /// Resolves the override for a given rule ID, preferring exact matches
    /// over wildcard patterns.
    ///
    /// - Parameter ruleId: The diagnostic's rule identifier.
    /// - Returns: The matching override, or nil if none applies.
    private func resolveOverride(for ruleId: String) -> SeverityOverride? {
        // Exact match takes precedence.
        if let exact = overrides[ruleId] {
            return exact
        }

        // Try wildcard: split on first "." and check for "prefix.*".
        if let dotIndex = ruleId.firstIndex(of: ".") {
            let prefix = String(ruleId[ruleId.startIndex..<dotIndex])
            let wildcardKey = "\(prefix).*"
            if let wildcard = overrides[wildcardKey] {
                return wildcard
            }
        }

        return nil
    }

    /// Creates a new diagnostic with a different severity, preserving all other fields.
    ///
    /// - Parameters:
    ///   - severity: The new severity level.
    ///   - diagnostic: The original diagnostic.
    /// - Returns: A new `Diagnostic` with the updated severity.
    private func withSeverity(_ severity: Diagnostic.Severity, for diagnostic: Diagnostic) -> Diagnostic {
        Diagnostic(
            severity: severity,
            message: diagnostic.message,
            filePath: diagnostic.filePath,
            lineNumber: diagnostic.lineNumber,
            columnNumber: diagnostic.columnNumber,
            ruleId: diagnostic.ruleId,
            suggestedFix: diagnostic.suggestedFix
        )
    }

    /// Recomputes the check status based on the remaining diagnostics.
    ///
    /// - Parameter diagnostics: The diagnostics after override processing.
    /// - Returns: The recomputed status.
    private func recomputeStatus(from diagnostics: [Diagnostic]) -> CheckResult.Status {
        let hasError = diagnostics.contains { $0.severity == .error }
        if hasError { return .failed }

        let hasWarning = diagnostics.contains { $0.severity == .warning }
        if hasWarning { return .warning }

        return .passed
    }
}
