import Foundation

/// Reports diagnostics in Xcode-compatible format for Build Phase integration.
///
/// Emits one line per diagnostic in the standard format Xcode parses
/// for inline annotations: `/path/file.swift:line:col: severity: message`
public struct XcodeReporter: Reporter, Sendable {

    /// Creates an Xcode reporter.
    public init() {}

    /// Writes diagnostics in Xcode-compatible `file:line:col: severity: message` format.
    public func report(_ results: [CheckResult], to output: inout some TextOutputStream) throws {
        for result in results {
            for diagnostic in result.diagnostics {
                writeDiagnostic(diagnostic, checkerId: result.checkerId, to: &output)
            }
        }
    }

    private func writeDiagnostic(
        _ diagnostic: Diagnostic,
        checkerId: String,
        to output: inout some TextOutputStream
    ) {
        let severity: String
        switch diagnostic.severity {
        case .error:
            severity = "error"
        case .warning:
            severity = "warning"
        case .note:
            severity = "note"
        }

        let ruleTag = diagnostic.ruleId.map { " [\($0)]" } ?? ""

        if let file = diagnostic.filePath {
            var location = file
            if let line = diagnostic.lineNumber {
                location += ":\(line)"
                if let column = diagnostic.columnNumber {
                    location += ":\(column)"
                }
            }
            output.write("\(location): \(severity): [\(checkerId)]\(ruleTag) \(diagnostic.message)\n")
        } else {
            output.write("\(severity): [\(checkerId)]\(ruleTag) \(diagnostic.message)\n")
        }
    }
}
