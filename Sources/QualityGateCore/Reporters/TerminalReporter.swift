import Foundation

/// Reports check results in a human-readable terminal format.
///
/// Uses ANSI colors and symbols for clear visual feedback.
public struct TerminalReporter: Reporter, Sendable {

    /// Creates a new TerminalReporter instance.
    public init() {}

    /// Outputs results in a human-readable terminal format.
    ///
    /// - Parameters:
    ///   - results: The check results to report.
    ///   - output: The text stream to write to.
    public func report(_ results: [CheckResult], to output: inout some TextOutputStream) throws {
        output.write("\n")
        output.write("==========================================\n")
        output.write("  Quality Gate Results\n")
        output.write("==========================================\n\n")

        var totalErrors = 0
        var totalWarnings = 0
        var allPassed = true

        for result in results {
            let statusSymbol = statusSymbol(for: result.status)
            let statusText = result.status.rawValue.uppercased()

            output.write("\(statusSymbol) [\(result.checkerId)] \(statusText)")
            output.write(" (\(formatDuration(result.duration)))\n")

            if result.status == .failed {
                allPassed = false
            }

            totalErrors += result.errorCount
            totalWarnings += result.warningCount

            // Print diagnostics
            for diagnostic in result.diagnostics {
                writeDiagnostic(diagnostic, to: &output)
            }

            if !result.diagnostics.isEmpty {
                output.write("\n")
            }
        }

        // Summary
        output.write("==========================================\n")
        if allPassed {
            output.write("✅ Quality Gate: PASSED\n")
        } else {
            output.write("❌ Quality Gate: FAILED\n")
        }

        if totalErrors > 0 || totalWarnings > 0 {
            output.write("   \(totalErrors) error(s), \(totalWarnings) warning(s)\n")
        }
        output.write("==========================================\n\n")
    }

    private func statusSymbol(for status: CheckResult.Status) -> String {
        switch status {
        case .passed:
            return "✓"
        case .failed:
            return "✗"
        case .warning:
            return "⚠"
        case .skipped:
            return "○"
        }
    }

    private func formatDuration(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds < 1 {
            return "\(Int(seconds * 1000))ms"
        } else {
            return "\(seconds.formatted(.number.precision(.fractionLength(2))))s"
        }
    }

    private func writeDiagnostic(_ diagnostic: Diagnostic, to output: inout some TextOutputStream) {
        let severityPrefix: String
        switch diagnostic.severity {
        case .error:
            severityPrefix = "  ❌ error:"
        case .warning:
            severityPrefix = "  ⚠️  warning:"
        case .note:
            severityPrefix = "  ℹ️  note:"
        }

        output.write("\(severityPrefix) \(diagnostic.message)\n")

        if let file = diagnostic.filePath {
            var location = "     → \(file)"
            if let line = diagnostic.lineNumber {
                location += ":\(line)"
                if let column = diagnostic.columnNumber {
                    location += ":\(column)"
                }
            }
            output.write("\(location)\n")
        }

        if let fix = diagnostic.suggestedFix {
            output.write("     💡 \(fix)\n")
        }
    }
}
