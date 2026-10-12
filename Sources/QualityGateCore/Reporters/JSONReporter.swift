import Foundation

/// Reports check results in JSON format for CI/CD integration.
///
/// Output structure:
/// ```json
/// {
///   "summary": { "status": "failed", "errors": 2, "warnings": 1 },
///   "results": [...]
/// }
/// ```
public struct JSONReporter: Reporter, Sendable {

    /// Whether a counted warning fails the run, as under `--strict`.
    public let strict: Bool

    /// Creates a new JSONReporter instance.
    ///
    /// - Parameter strict: Whether a non-zero `totalWarnings` makes the summary status
    ///   `failed`, matching the CLI's exit code under `--strict`.
    public init(strict: Bool = false) {
        self.strict = strict
    }

    /// Outputs results in JSON format for programmatic consumption.
    ///
    /// - Parameters:
    ///   - results: The check results to report.
    ///   - output: The text stream to write to.
    public func report(_ results: [CheckResult], to output: inout some TextOutputStream) throws {
        let report = JSONReport(results: results, strict: strict)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(report)
        guard let json = String(data: data, encoding: .utf8) else {
            throw QualityGateError.configurationError("Failed to encode JSON output")
        }

        output.write(json)
        output.write("\n")
    }
}

// MARK: - JSON Report Model

private struct JSONReport: Codable {
    let summary: Summary
    let results: [CheckResult]

    init(results: [CheckResult], strict: Bool) {
        // Reconciled so each result's `status` is the one the summary was computed from.
        let reconciled = results.map { $0.reconciled() }
        self.results = reconciled
        self.summary = Summary(from: reconciled, strict: strict)
    }

    struct Summary: Codable {
        let status: String
        let totalChecks: Int
        let passed: Int
        let failed: Int
        let warnings: Int
        let skipped: Int
        let totalErrors: Int
        let totalWarnings: Int
        let totalDuration: Double

        init(from results: [CheckResult], strict: Bool) {
            // Every count and the status come off one tally — the same one the terminal
            // summary and the exit code read. `warnings` is the number of checkers that
            // warned; `totalWarnings` is the number of warning findings, and is what
            // `--strict` gates on.
            let tally = RunTally(results)
            totalChecks = results.count
            passed = tally.passedCheckers.count
            failed = tally.failedCheckers.count
            warnings = tally.warnedCheckers.count
            skipped = tally.skippedCheckers.count
            totalErrors = tally.errors
            totalWarnings = tally.warnings

            let totalDurationValue = results.reduce(Duration.zero) { sum, result in
                sum + result.duration
            }
            totalDuration = Double(totalDurationValue.components.seconds) +
                           Double(totalDurationValue.components.attoseconds) / 1e18

            // This reporter is not told whether the run was truncated, so it cannot say
            // `incomplete`; the exit code still does.
            status = tally.verdict(strict: strict, truncated: false) == .passed ? "passed" : "failed"
        }
    }
}

// MARK: - Duration Zero Extension

extension Duration {
    static var zero: Duration {
        .seconds(0)
    }
}
