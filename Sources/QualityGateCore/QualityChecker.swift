import Foundation
@_exported import QualityGateTypes

/// Protocol that all quality checkers must implement.
///
/// Each checker is responsible for a specific category of quality checks,
/// such as building, testing, safety auditing, or documentation linting.
///
/// ## Implementing a Checker
///
/// ```swift
/// struct MyChecker: QualityChecker {
///     let id = "my-checker"
///     let name = "My Custom Checker"
///
///     func check(configuration: Configuration) async throws -> CheckResult {
///         // Perform checks...
///         return CheckResult(
///             checkerId: id,
///             status: .passed,
///             diagnostics: [],
///             duration: .seconds(1)
///         )
///     }
/// }
/// ```
public protocol QualityChecker: Sendable {

    /// Unique identifier for this checker.
    ///
    /// Used in configuration files and CLI arguments to reference this checker.
    /// Convention: lowercase with hyphens (e.g., "doc-lint", "safety").
    var id: String { get }

    /// Human-readable name for display.
    ///
    /// Shown in terminal output and reports.
    var name: String { get }

    /// Run the quality check and return results.
    ///
    /// - Parameter configuration: Project-specific configuration.
    /// - Returns: The check result with status and diagnostics.
    /// - Throws: `QualityGateError` if the check cannot be completed.
    func check(configuration: Configuration) async throws -> CheckResult

    /// Whether this checker is safe to run concurrently with other checkers.
    ///
    /// Defaults to `true` (pure AST/file analysis is read-only and parallel-safe).
    /// Checkers that spawn `swift build`/`swift test` (locking the SwiftPM `.build`
    /// directory) or mutate the build tree must return `false` so the runner executes
    /// them sequentially, outside the concurrent task group.
    var isParallelSafe: Bool { get }
}

public extension QualityChecker {
    /// Default: checkers are parallel-safe unless they opt out.
    var isParallelSafe: Bool { true }
}
