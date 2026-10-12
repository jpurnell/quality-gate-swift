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

        // Every finding hidden or lowered here is recorded as it goes. `off` used to be a bare
        // `return nil`, and a finding removed that way appeared in no output format at all.
        var recorded: [DiagnosticOverride] = []
        let alreadyRecorded = Set(result.overrides.map(RecordKey.init))
        func record(_ override: DiagnosticOverride) {
            // Idempotent: the transform this runs in may see a result twice (the consistency
            // stage re-applies it), and a finding lowered to a note is still there to match.
            if !alreadyRecorded.contains(RecordKey(override)) { recorded.append(override) }
        }

        let processedDiagnostics = result.diagnostics.compactMap { diagnostic -> Diagnostic? in
            // Rule-based overrides first.
            if let ruleId = diagnostic.ruleId, let (key, override) = resolveOverride(for: ruleId) {
                let target: Diagnostic.Severity?
                switch override {
                case .off: target = nil
                case .error: target = .error
                case .warning: target = .warning
                case .info: target = .note
                }
                // Only a lowering is a suppression. Raising a rule's severity hides nothing.
                if target.map({ $0 < diagnostic.severity }) ?? true {
                    let was = target == nil ? "" : " (was \(diagnostic.severity.rawValue))"
                    record(.configuration(
                        form: "config overrides: \(override.rawValue)",
                        ruleId: ruleId,
                        filePath: diagnostic.filePath,
                        findingLine: diagnostic.lineNumber,
                        entry: "overrides: \(key): \(override.rawValue)\(was)",
                        reportOnly: true))
                }
                return target.map { withSeverity($0, for: diagnostic) }
            }

            // Vendor path demotion: demote warnings/errors to notes.
            if diagnostic.severity != .note,
               let filePath = diagnostic.filePath,
               let vendor = vendorPath(containing: filePath) {
                record(.configuration(
                    form: "config vendorPaths",
                    ruleId: diagnostic.ruleId ?? "(no rule id)",
                    filePath: filePath,
                    findingLine: diagnostic.lineNumber,
                    entry: "vendorPaths: \(vendor) (was \(diagnostic.severity.rawValue))",
                    reportOnly: true))
                return withSeverity(.note, for: diagnostic)
            }

            return diagnostic
        }

        let newStatus = recomputeStatus(from: processedDiagnostics)

        return CheckResult(
            checkerId: result.checkerId,
            status: newStatus,
            diagnostics: processedDiagnostics,
            overrides: result.overrides + recorded,
            complianceRecords: result.complianceRecords,
            duration: result.duration
        )
    }

    // MARK: - Private Helpers

    /// What makes two override records the same record.
    private struct RecordKey: Hashable {
        let ruleId: String
        let justification: String
        let filePath: String?
        let lineNumber: Int?

        init(_ override: DiagnosticOverride) {
            ruleId = override.ruleId
            justification = override.justification
            filePath = override.filePath
            lineNumber = override.lineNumber
        }
    }

    /// The configured vendor path the file falls under, if any.
    private func vendorPath(containing filePath: String) -> String? {
        vendorPaths.first { vendor in
            filePath.contains("/\(vendor)/")
        }
    }

    /// Resolves the override for a given rule ID, preferring exact matches
    /// over wildcard patterns.
    ///
    /// - Parameter ruleId: The diagnostic's rule identifier.
    /// - Returns: The matching override and the key it was written under, or nil if none
    ///   applies.
    private func resolveOverride(for ruleId: String) -> (key: String, override: SeverityOverride)? {
        // Exact match takes precedence.
        if let exact = overrides[ruleId] {
            return (ruleId, exact)
        }

        // Try wildcard: split on first "." and check for "prefix.*".
        if let dotIndex = ruleId.firstIndex(of: ".") {
            let prefix = String(ruleId[ruleId.startIndex..<dotIndex])
            let wildcardKey = "\(prefix).*"
            if let wildcard = overrides[wildcardKey] {
                return (wildcardKey, wildcard)
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
            suggestedFix: diagnostic.suggestedFix,
            origin: diagnostic.origin,
            endLine: diagnostic.endLine
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
