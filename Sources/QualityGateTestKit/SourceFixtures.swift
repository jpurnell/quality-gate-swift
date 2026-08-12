import Foundation

/// Common Swift source patterns for testing checkers.
///
/// These fixtures provide well-known code snippets that trigger (or avoid)
/// specific auditor rules. Use them to write concise, readable tests without
/// duplicating boilerplate source strings across test files.
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
///     let summary = "Findings the auditor under test reports"
///     let category = CheckerCategory.safetySecurity
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
///     SourceFixtures.forceUnwrapPatterns,
///     with: ExampleAuditor()
/// )
/// expectDiagnostic(in: result, ruleId: "force-unwrap")
/// ```
public enum SourceFixtures {

    /// Minimal valid Swift file.
    public static let minimalValid = """
    /// A minimal valid type.
    public struct Minimal {
        /// A sample value.
        public let value: Int
    }
    """

    /// Empty source file.
    public static let empty = ""

    /// Class with stored properties and deinit.
    public static let classWithDeinit = """
    /// A class with proper lifecycle management.
    public class ManagedObject {
        /// The managed task.
        public var task: Task<Void, Never>?
        deinit { task?.cancel() }
    }
    """

    /// Source with force-unwrap patterns (should trigger SafetyAuditor).
    public static let forceUnwrapPatterns = """
    func riskyCode() {
        let x: Int? = nil
        let y = x!
        let z = someOptional as! String
    }
    """

    /// Actor with isolated state.
    public static let basicActor = """
    /// A basic actor for testing.
    public actor Counter {
        /// The current count.
        private var count = 0
        /// Increment and return new value.
        public func increment() -> Int {
            count += 1
            return count
        }
    }
    """
}
