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

    /// Whether the run is under `--strict`, where a counted warning fails the run.
    ///
    /// The verdict line and the `N warning(s)` line are both read off one ``RunTally``, so
    /// under `--strict` a run that prints a non-zero warning count prints FAILED — whatever
    /// status the checker that emitted the warning chose for itself.
    public let strict: Bool

    /// Configured exclusions in force for the run.
    ///
    /// Printed under the totals, apart from them: a path left out of the walk hid an
    /// unknown number of findings, and an unknown number does not belong in a sum.
    public let exclusions: [ActiveExclusion]

    /// The repository's `suppressions:` policy, so the summary can say whether the
    /// suppressions it counts gate.
    public let suppressionPolicy: SuppressionPolicy

    /// Creates a new TerminalReporter instance.
    ///
    /// - Parameters:
    ///   - rosterSize: Total registered checkers, so the summary can state its
    ///     denominator. `nil` omits the line rather than guessing.
    ///   - truncation: How the run stopped early; `nil` for a complete run.
    ///   - strict: Whether a counted warning fails the run, as under `--strict`.
    ///   - exclusions: Configured exclusions in force for the run.
    ///   - suppressionPolicy: The repository's `suppressions:` policy.
    public init(
        rosterSize: Int? = nil,
        truncation: RunTruncation? = nil,
        strict: Bool = false,
        exclusions: [ActiveExclusion] = [],
        suppressionPolicy: SuppressionPolicy = .note
    ) {
        self.rosterSize = rosterSize
        self.truncation = truncation
        self.strict = strict
        self.exclusions = exclusions
        self.suppressionPolicy = suppressionPolicy
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

        // Reconciled here as well as in the runner, so the status printed beside each
        // checker is the one the verdict below was computed from, whoever built the list.
        let results = results.map { $0.reconciled() }
        // One tally. The verdict line and the count line both read it, so the number
        // after "warning(s)" is the number `--strict` gated on.
        let tally = RunTally(results)

        for result in results {
            let statusSymbol = statusSymbol(for: result.status)
            let statusText = result.status.rawValue.uppercased()

            output.write("\(statusSymbol) [\(result.checkerId)] \(statusText)")
            output.write(" (\(formatDuration(result.duration)))\n")

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
        let stoppedAt = truncation.map { "run stopped at [\($0.stoppedAt)]" }
        switch tally.verdict(strict: strict, truncated: truncation != nil) {
        case .passed:
            output.write("✅ Quality Gate: PASSED\n")
        case .failed:
            output.write("❌ Quality Gate: FAILED\(stoppedAt.map { " (\($0))" } ?? "")\n")
        case .failedByStrictWarnings:
            // Names the count it gated on — the same stored number the line below prints.
            let counted = "\(tally.warnings) warning\(tally.warnings == 1 ? "" : "s")"
            output.write(
                "❌ Quality Gate: FAILED (--strict: \(counted)\(stoppedAt.map { "; \($0)" } ?? ""))\n")
        case .incomplete:
            // Truncated, yet nothing that ran failed — reachable in any repository holding
            // a baseline ledger. The runner stops at a checker that genuinely failed, then
            // `BaselineLedger.apply` turns that checker's errors into notes and recomputes
            // its verdict to `.passed`, leaving every result green with the truncation
            // still recorded. A tick there would sit over an unexamined majority. Neither
            // pass nor fail is true: the run did not answer the question, and saying so is
            // the only honest verdict.
            let unreached = truncation?.unreached.count ?? 0
            output.write(
                "⚠️  Quality Gate: INCOMPLETE (\(stoppedAt ?? "run stopped early")"
                + ", \(unreached) checker(s) never ran)\n")
        }

        if tally.errors > 0 || tally.warnings > 0 {
            output.write("   \(tally.errors) error(s), \(tally.warnings) warning(s)\n")
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
        writeSuppressions(SuppressionLedger(results: results, exclusions: exclusions), to: &output)
        output.write("==========================================\n\n")
    }

    /// Writes what the run was told not to raise.
    ///
    /// Nothing is printed for a run that silenced nothing: a block on every run stops being
    /// read, and this one needs reading on the runs where it appears. When it does appear it
    /// keeps three numbers apart that a single "overrides" count would merge — a reason the
    /// gate validated, a marker it did not, and debt on the decaying ledger.
    private func writeSuppressions(_ ledger: SuppressionLedger, to output: inout some TextOutputStream) {
        let overall = ledger.overall
        if !overall.isEmpty {
            var parts = [
                "\(overall.acknowledged) acknowledged (reason validated)",
                "\(overall.suppressed) suppressed (not validated)",
            ]
            if overall.baselined > 0 { parts.append("\(overall.baselined) baselined") }
            output.write("   Silenced findings: " + parts.joined(separator: " · ") + "\n")
            if !overall.suppressedByForm.isEmpty {
                output.write("     suppressed by form: \(Self.byForm(overall.suppressedByForm))\n")
            }
            if !overall.acknowledgedByForm.isEmpty {
                output.write("     acknowledged by form: \(Self.byForm(overall.acknowledgedByForm))\n")
            }
            let perChecker = ledger.checkers.filter { !$0.totals.isEmpty }.map { entry -> String in
                var counts: [String] = []
                if entry.totals.acknowledged > 0 { counts.append("\(entry.totals.acknowledged) acknowledged") }
                if entry.totals.suppressed > 0 { counts.append("\(entry.totals.suppressed) suppressed") }
                if entry.totals.baselined > 0 { counts.append("\(entry.totals.baselined) baselined") }
                return "\(entry.checkerId) " + counts.joined(separator: ", ")
            }
            output.write("     by checker: " + perChecker.joined(separator: " · ") + "\n")
            if overall.suppressed > 0 {
                switch suppressionPolicy {
                case .note:
                    output.write(
                        "     ℹ️  note: \(overall.suppressed) suppressed finding(s) do not gate (suppressions: note). "
                        + "Set `suppressions: warn` in .quality-gate.yml to gate on them; --format json lists each one.\n")
                case .warn, .error:
                    output.write(
                        "     ℹ️  note: \(overall.suppressed) suppressed finding(s) are reported as "
                        + "\(SuppressionRatchet.ruleID) (suppressions: \(suppressionPolicy.rawValue)).\n")
                }
            }
        }
        if !ledger.exclusions.isEmpty {
            output.write("   Exclusions in force (what they hid is not measured):\n")
            for exclusion in ledger.exclusions {
                output.write("     \(exclusion.form) — \(exclusion.detail)\n")
            }
        }
    }

    /// Counts by form, largest first and then by name, so the line is the same on every run.
    private static func byForm(_ counts: [String: Int]) -> String {
        counts
            .sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
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
