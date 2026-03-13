import Foundation

/// Errors that can occur during quality gate execution.
///
/// These errors are documented in the project's Error Registry
/// (see 00_MASTER_PLAN.md).
public enum QualityGateError: Error, Sendable, LocalizedError {

    /// Swift build failed with the given exit code and output.
    case buildFailed(exitCode: Int32, output: String)

    /// One or more tests failed.
    case testsFailed(count: Int)

    /// Safety violations were detected (force unwraps, etc.).
    case safetyViolation(count: Int)

    /// Documentation linting found issues.
    case docLintFailed(issueCount: Int)

    /// Configuration file is invalid.
    case configurationError(String)

    /// An external command timed out.
    case processTimeout(command: String, timeout: Duration)

    /// User-friendly error description.
    public var errorDescription: String? {
        switch self {
        case .buildFailed(let exitCode, _):
            return "Build failed with exit code \(exitCode)"
        case .testsFailed(let count):
            return "\(count) test\(count == 1 ? "" : "s") failed"
        case .safetyViolation(let count):
            return "\(count) safety violation\(count == 1 ? "" : "s") detected"
        case .docLintFailed(let issueCount):
            return "Documentation has \(issueCount) issue\(issueCount == 1 ? "" : "s")"
        case .configurationError(let description):
            return "Configuration error: \(description)"
        case .processTimeout(let command, let timeout):
            let seconds = Double(timeout.components.seconds)
            return "Command '\(command)' timed out after \(seconds) seconds"
        }
    }
}
