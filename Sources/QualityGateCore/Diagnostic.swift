import Foundation

/// A single diagnostic message from a quality check.
///
/// Diagnostics represent individual issues found during quality checking,
/// such as compile errors, test failures, or safety violations.
///
/// ## Usage
///
/// ```swift
/// let diagnostic = Diagnostic(
///     severity: .error,
///     message: "Force unwrap detected",
///     file: "/path/to/File.swift",
///     line: 42,
///     column: 15,
///     ruleId: "force-unwrap",
///     suggestedFix: "Use optional binding instead"
/// )
/// ```
///
/// ## MCP Schema
///
/// **Parameter Types:**
/// - severity (string): One of "error", "warning", or "note"
/// - message (string): Human-readable description of the issue
/// - file (string, optional): Absolute path to the source file
/// - line (integer, optional): 1-based line number
/// - column (integer, optional): 1-based column number
/// - ruleId (string, optional): Identifier for the rule that triggered this
/// - suggestedFix (string, optional): How to resolve the issue
///
/// ```json
/// {
///   "severity": "error",
///   "message": "Force unwrap detected",
///   "file": "/path/to/File.swift",
///   "line": 42,
///   "column": 15,
///   "ruleId": "force-unwrap",
///   "suggestedFix": "Use optional binding instead"
/// }
/// ```
public struct Diagnostic: Sendable, Codable, Equatable {

    /// The severity level of the diagnostic.
    public enum Severity: String, Sendable, Codable, Comparable {
        case error
        case warning
        case note

        /// Compares severity levels. Error > Warning > Note.
        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            let order: [Severity] = [.note, .warning, .error]
            guard let lhsIndex = order.firstIndex(of: lhs),
                  let rhsIndex = order.firstIndex(of: rhs) else {
                return false
            }
            return lhsIndex < rhsIndex
        }
    }

    /// The severity of this diagnostic.
    public let severity: Severity

    /// The diagnostic message describing the issue.
    public let message: String

    /// The file path where the issue was found, if applicable.
    public let file: String?

    /// The line number where the issue was found, if applicable.
    public let line: Int?

    /// The column number where the issue was found, if applicable.
    public let column: Int?

    /// The identifier of the rule that triggered this diagnostic, if applicable.
    public let ruleId: String?

    /// A suggested fix for the issue, if available.
    public let suggestedFix: String?

    /// Creates a new diagnostic.
    ///
    /// - Parameters:
    ///   - severity: The severity level.
    ///   - message: The diagnostic message.
    ///   - file: The file path (optional).
    ///   - line: The line number (optional).
    ///   - column: The column number (optional).
    ///   - ruleId: The rule identifier (optional).
    ///   - suggestedFix: A suggested fix (optional).
    public init(
        severity: Severity,
        message: String,
        file: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        ruleId: String? = nil,
        suggestedFix: String? = nil
    ) {
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.column = column
        self.ruleId = ruleId
        self.suggestedFix = suggestedFix
    }
}
