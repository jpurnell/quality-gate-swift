import Foundation
import QualityGateCore

/// A quality checker that can audit a single source string.
///
/// Many syntax-based auditors implement an `auditSource(_:fileName:configuration:)`
/// method, but it is not part of the ``QualityChecker`` protocol. This protocol
/// captures that capability so ``auditSource(_:fileName:with:configuration:)``
/// can work generically.
///
/// ## Conforming Your Auditor
///
/// If your auditor already has the matching method, the conformance itself is a
/// single line:
///
/// ```swift
/// import QualityGateCore
///
/// // Your auditor, in its own module. It already has the matching method.
/// struct MyAuditor: QualityChecker {
///     let id = "my-rule"
///     let name = "My Rule"
///     let summary = "Findings this rule reports, in one noun phrase"
///     let category = CheckerCategory.codeHygiene
///
///     func check(configuration: Configuration) async throws -> CheckResult {
///         CheckResult(checkerId: id, status: .passed, diagnostics: [], duration: .zero)
///     }
///
///     func auditSource(
///         _ source: String, fileName: String, configuration: Configuration
///     ) async throws -> CheckResult {
///         CheckResult(checkerId: id, status: .passed, diagnostics: [], duration: .zero)
///     }
/// }
///
/// extension MyAuditor: SourceAuditable {}
/// ```
public protocol SourceAuditable: QualityChecker {
    /// Audit a single Swift source string and return a check result.
    ///
    /// - Parameters:
    ///   - source: Swift source code to audit.
    ///   - fileName: Simulated file name for diagnostics.
    ///   - configuration: The project configuration.
    /// - Returns: A check result with any violations found.
    func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult
}
