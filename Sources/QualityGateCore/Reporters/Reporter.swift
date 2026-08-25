import Foundation

/// Output format for check results.
public enum OutputFormat: String, Sendable, CaseIterable {
    case terminal
    case json
    case sarif
    case xcode
}

/// Protocol for outputting check results.
///
/// Reporters transform `CheckResult` arrays into formatted output
/// suitable for different consumers (humans, CI systems, etc.).
public protocol Reporter: Sendable {

    /// Report the results to an output stream.
    ///
    /// - Parameters:
    ///   - results: The check results to report.
    ///   - output: The output stream to write to.
    /// - Throws: If writing fails.
    func report(_ results: [CheckResult], to output: inout some TextOutputStream) throws
}

/// Factory for creating reporters.
public enum ReporterFactory {

    /// Creates a reporter for the specified format.
    ///
    /// - Parameters:
    ///   - format: The desired output format.
    ///   - rosterSize: Total registered checkers, so a terminal summary can state its
    ///     denominator. `nil` omits the line rather than guessing at it.
    ///   - truncation: How the run stopped early, so a terminal summary can distinguish
    ///     "not selected" from "never reached". `nil` for a complete run.
    /// - Returns: A reporter instance.
    public static func create(
        for format: OutputFormat,
        rosterSize: Int? = nil,
        truncation: RunTruncation? = nil
    ) -> any Reporter {
        switch format {
        case .terminal:
            return TerminalReporter(rosterSize: rosterSize, truncation: truncation)
        case .json:
            return JSONReporter()
        case .sarif:
            return SARIFReporter()
        case .xcode:
            return XcodeReporter()
        }
    }
}
