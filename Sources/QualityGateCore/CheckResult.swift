import Foundation

/// The result of a quality check execution.
///
/// Each `QualityChecker` returns a `CheckResult` indicating whether
/// the check passed, failed, or had warnings.
///
/// ## MCP Schema
/// ```json
/// {
///   "checkerId": "safety",
///   "status": "failed",
///   "diagnostics": [...],
///   "duration": 0.25
/// }
/// ```
public struct CheckResult: Sendable, Codable, Equatable {

    /// The status of a quality check.
    public enum Status: String, Sendable, Codable {
        case passed
        case failed
        case warning
        case skipped

        /// Whether this status indicates the check did not fail.
        public var isPassing: Bool {
            switch self {
            case .passed, .warning, .skipped:
                return true
            case .failed:
                return false
            }
        }
    }

    /// The identifier of the checker that produced this result.
    public let checkerId: String

    /// The overall status of the check.
    public let status: Status

    /// Any diagnostics produced during the check.
    public let diagnostics: [Diagnostic]

    /// How long the check took to execute.
    public let duration: Duration

    /// Creates a new check result.
    ///
    /// - Parameters:
    ///   - checkerId: The checker's identifier.
    ///   - status: The check status.
    ///   - diagnostics: Any diagnostics produced.
    ///   - duration: The execution duration.
    public init(
        checkerId: String,
        status: Status,
        diagnostics: [Diagnostic],
        duration: Duration
    ) {
        self.checkerId = checkerId
        self.status = status
        self.diagnostics = diagnostics
        self.duration = duration
    }

    /// The count of error-severity diagnostics.
    public var errorCount: Int {
        diagnostics.filter { $0.severity == .error }.count
    }

    /// The count of warning-severity diagnostics.
    public var warningCount: Int {
        diagnostics.filter { $0.severity == .warning }.count
    }
}
