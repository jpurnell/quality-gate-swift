import Foundation
import QualityGateCore

/// Run a checker against an inline Swift source string and return the result.
///
/// This is the primary entry point for testing syntax-based auditors. It wraps
/// the auditor's ``SourceAuditable/auditSource(_:fileName:configuration:)``
/// method with sensible defaults for test usage.
///
/// ## Example
///
/// ```swift
/// import QualityGateCore
/// import Testing
///
/// // Stands in for the auditor under test; yours lives in its own module.
/// struct ExampleAuditor: SourceAuditable {
///     let id = "force-unwrap"
///     let name = "Example Auditor"
///
///     func check(configuration: Configuration) async throws -> CheckResult {
///         CheckResult(checkerId: id, status: .passed, diagnostics: [], duration: .zero)
///     }
///
///     func auditSource(
///         _ source: String, fileName: String, configuration: Configuration
///     ) async throws -> CheckResult {
///         let hits = source.contains("!")
///             ? [Diagnostic(severity: .error, message: "Force unwrap", filePath: fileName, ruleId: id)]
///             : []
///         return CheckResult(
///             checkerId: id,
///             status: hits.isEmpty ? .passed : .failed,
///             diagnostics: hits,
///             duration: .zero)
///     }
/// }
///
/// let result = try await auditSource(
///     "let x = optional!",
///     with: ExampleAuditor()
/// )
/// expectDiagnostic(in: result, ruleId: "force-unwrap")
/// ```
///
/// - Parameters:
///   - source: Swift source code to audit.
///   - fileName: Simulated file name (default: "Test.swift").
///   - checker: The quality checker to run. Must conform to ``SourceAuditable``.
///   - configuration: Configuration to use (default: `.init()`).
/// - Returns: The check result with diagnostics.
public func auditSource(
    _ source: String,
    fileName: String = "Test.swift",
    with checker: some SourceAuditable,
    configuration: Configuration = Configuration()
) async throws -> CheckResult {
    return try await checker.auditSource(source, fileName: fileName, configuration: configuration)
}
