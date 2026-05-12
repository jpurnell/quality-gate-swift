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
/// let result = try await auditSource(
///     "let x = optional!",
///     with: SafetyAuditor()
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
