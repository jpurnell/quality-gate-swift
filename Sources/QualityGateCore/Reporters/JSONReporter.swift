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

    /// Creates a new JSONReporter instance.
    public init() {}

    /// Outputs results in JSON format for programmatic consumption.
    ///
    /// - Parameters:
    ///   - results: The check results to report.
    ///   - output: The text stream to write to.
    public func report(_ results: [CheckResult], to output: inout some TextOutputStream) throws {
        let report = JSONReport(results: results)

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

    init(results: [CheckResult]) {
        self.results = results
        self.summary = Summary(from: results)
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

        init(from results: [CheckResult]) {
            totalChecks = results.count
            passed = results.filter { $0.status == .passed }.count
            failed = results.filter { $0.status == .failed }.count
            warnings = results.filter { $0.status == .warning }.count
            skipped = results.filter { $0.status == .skipped }.count
            totalErrors = results.reduce(0) { $0 + $1.errorCount }
            totalWarnings = results.reduce(0) { $0 + $1.warningCount }

            let totalDurationValue = results.reduce(Duration.zero) { sum, result in
                sum + result.duration
            }
            totalDuration = Double(totalDurationValue.components.seconds) + // fp-safety:disable
                           Double(totalDurationValue.components.attoseconds) / 1e18

            status = failed > 0 ? "failed" : "passed"
        }
    }
}

// MARK: - Duration Zero Extension

extension Duration {
    static var zero: Duration {
        .seconds(0)
    }
}
