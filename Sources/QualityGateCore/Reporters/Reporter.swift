import Foundation

/// Output format for check results.
public enum OutputFormat: String, Sendable, CaseIterable {
    case terminal
    case json
    case sarif
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
    /// - Parameter format: The desired output format.
    /// - Returns: A reporter instance.
    public static func create(for format: OutputFormat) -> any Reporter {
        switch format {
        case .terminal:
            return TerminalReporter()
        case .json:
            return JSONReporter()
        case .sarif:
            return SARIFReporter()
        }
    }
}
