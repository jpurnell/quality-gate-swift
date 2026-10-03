import Foundation

/// Reports check results in a human-readable terminal format.
///
/// Uses ANSI colors and symbols for clear visual feedback.
public struct TerminalReporter: Reporter, Sendable {

    /// How many checkers the registry holds, when the caller knows.
    ///
    /// The summary reports what the run *found*. Without this it cannot report what the
    /// run *was* — and a 35-checker run prints exactly what a 42-checker run prints.
    /// BusinessMath ran 35 of 42 for as long as its config file existed, because a
    /// mistyped key silently selected a narrower set; one line here would have made that
    /// visible on every run, to anyone, without archaeology.
    public let rosterSize: Int?

    /// How the run stopped early, when it did.
    ///
    /// "Not selected" and "not reached" are opposite statements: the first is a choice,
    /// the second is an absence of evidence. A default run stops at its first failing
    /// checker, and for as long as the summary collapsed the two, a truncated run's tail
    /// read as clean — the mechanism that hid one package's false positives for months.
    public let truncation: RunTruncation?

    /// Whether the run is under `--strict`, where a checker that warned fails the run.
    ///
    /// The CLI's exit code already applied that rule; the summary did not, so a `--strict`
    /// run that exited 1 on a warning printed `✅ Quality Gate: PASSED` above it.
    public let strict: Bool

    /// Creates a new TerminalReporter instance.
    ///
    /// - Parameters:
    ///   - rosterSize: Total registered checkers, so the summary can state its
    ///     denominator. `nil` omits the line rather than guessing.
    ///   - truncation: How the run stopped early; `nil` for a complete run.
    ///   - strict: Whether a `.warning` result fails the run, as under `--strict`.
    public init(rosterSize: Int? = nil, truncation: RunTruncation? = nil, strict: Bool = false) {
        self.rosterSize = rosterSize
        self.truncation = truncation
        self.strict = strict
    }

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
        var failedOnlyByStrictWarnings = false

        for result in results {
            let statusSymbol = statusSymbol(for: result.status)
            let statusText = result.status.rawValue.uppercased()

            output.write("\(statusSymbol) [\(result.checkerId)] \(statusText)")
            output.write(" (\(formatDuration(result.duration)))\n")

            if result.status == .failed {
                allPassed = false
            } else if strict && result.status == .warning {
                allPassed = false
                failedOnlyByStrictWarnings = true
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
        // Truncation is asked about FIRST, and deliberately. `allPassed` is computed over
        // the checkers that *ran*, so a truncated run whose executed subset is green used
        // to satisfy it and print a tick over an unexamined majority. That is reachable in
        // any repository holding a baseline ledger: the runner stops at a checker that
        // genuinely failed, then `BaselineLedger.apply` turns that checker's errors into
        // notes and recomputes its verdict to `.passed`, leaving every result green and
        // the truncation still recorded. The honest verdict for "some checkers never ran"
        // is neither pass nor fail — it is that the question was not answered.
        if let truncation, allPassed {
            // Truncated, yet everything that ran is green — reachable in any repository
            // holding a baseline ledger. The runner stops at a checker that genuinely
            // failed, then `BaselineLedger.apply` turns that checker's errors into notes
            // and recomputes its verdict to `.passed`, leaving every result green with the
            // truncation still recorded. Neither pass nor fail is true here: the run did
            // not answer the question, and saying so is the only honest verdict.
            output.write(
                "⚠️  Quality Gate: INCOMPLETE (run stopped at [\(truncation.stoppedAt)]"
                + ", \(truncation.unreached.count) checker(s) never ran)\n")
        } else if let truncation {
            output.write("❌ Quality Gate: FAILED (run stopped at [\(truncation.stoppedAt)])\n")
        } else if allPassed {
            output.write("✅ Quality Gate: PASSED\n")
        } else if failedOnlyByStrictWarnings && !results.contains(where: { $0.status == .failed }) {
            output.write("❌ Quality Gate: FAILED (--strict: a checker warned)\n")
        } else {
            output.write("❌ Quality Gate: FAILED\n")
        }

        if totalErrors > 0 || totalWarnings > 0 {
            output.write("   \(totalErrors) error(s), \(totalWarnings) warning(s)\n")
        }
        // Every run states its denominator, and states it in three parts when they
        // differ: ran, deliberately not selected, and never reached. The last two must
        // not be collapsed — a checker that was not selected was a choice; a checker
        // that was not reached contributed no evidence, and zero findings from it
        // means nothing.
        if let rosterSize, rosterSize > 0 {
            let ran = results.count
            let unreachedCount = truncation?.unreached.count ?? 0
            var line = "   \(ran) of \(rosterSize) checkers"
            let notSelected = rosterSize - ran - unreachedCount
            if notSelected > 0 { line += " · \(notSelected) not selected" }
            if unreachedCount > 0 {
                line += " · \(unreachedCount) NOT REACHED — 0 findings from them means nothing"
            }
            output.write(line + "\n")
            if unreachedCount > 0 {
                output.write("   → re-run with --continue-on-failure for the full picture\n")
            }
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
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 // fp-safety:disable
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
