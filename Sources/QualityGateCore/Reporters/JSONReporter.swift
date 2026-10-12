import Foundation

/// Reports check results in JSON format for CI/CD integration.
///
/// Output structure:
/// ```json
/// {
///   "summary": { "status": "failed", "errors": 2, "warnings": 1, "suppressions": { ... } },
///   "results": [...]
/// }
/// ```
///
/// ## What was silenced
///
/// `summary.suppressions` carries the run's totals — `acknowledged`, `suppressed`,
/// `baselined`, each by form, per checker under `byChecker` — with the `policy` in force and
/// the configured `exclusions`. Each element of `results` keeps every published
/// `CheckResult` field and gains two: `suppressions`, the result's ``SuppressionRecord``s,
/// and `suppressionTotals`. The published `overrides` array is still emitted; `suppressions`
/// is the same information decoded, so a consumer does not have to parse a justification.
public struct JSONReporter: Reporter, Sendable {

    /// Whether a counted warning fails the run, as under `--strict`.
    public let strict: Bool

    /// Configured exclusions in force for the run.
    public let exclusions: [ActiveExclusion]

    /// The repository's `suppressions:` policy.
    public let suppressionPolicy: SuppressionPolicy

    /// Creates a new JSONReporter instance.
    ///
    /// - Parameters:
    ///   - strict: Whether a non-zero `totalWarnings` makes the summary status `failed`,
    ///     matching the CLI's exit code under `--strict`.
    ///   - exclusions: Configured exclusions in force for the run.
    ///   - suppressionPolicy: The repository's `suppressions:` policy.
    public init(
        strict: Bool = false,
        exclusions: [ActiveExclusion] = [],
        suppressionPolicy: SuppressionPolicy = .note
    ) {
        self.strict = strict
        self.exclusions = exclusions
        self.suppressionPolicy = suppressionPolicy
    }

    /// Outputs results in JSON format for programmatic consumption.
    ///
    /// - Parameters:
    ///   - results: The check results to report.
    ///   - output: The text stream to write to.
    public func report(_ results: [CheckResult], to output: inout some TextOutputStream) throws {
        let report = JSONReport(
            results: results, strict: strict, exclusions: exclusions, policy: suppressionPolicy)

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

private struct JSONReport: Encodable {
    let summary: Summary
    let results: [ReportedResult]

    init(results: [CheckResult], strict: Bool, exclusions: [ActiveExclusion], policy: SuppressionPolicy) {
        // Reconciled so each result's `status` is the one the summary was computed from.
        let reconciled = results.map { $0.reconciled() }
        let ledger = SuppressionLedger(results: reconciled, exclusions: exclusions)
        self.results = zip(reconciled, ledger.checkers).map { result, entry in
            ReportedResult(result: result, suppressions: entry.records, suppressionTotals: entry.totals)
        }
        self.summary = Summary(from: reconciled, strict: strict, ledger: ledger, policy: policy)
    }

    /// A result as published, plus its suppression records decoded.
    ///
    /// `CheckResult` encodes itself — its keys are the published contract and are not
    /// restated here — and the two additions go into the same object beside them.
    struct ReportedResult: Encodable {
        let result: CheckResult
        let suppressions: [SuppressionRecord]
        let suppressionTotals: SuppressionTotals

        private enum AddedKeys: String, CodingKey {
            case suppressions, suppressionTotals
        }

        func encode(to encoder: Encoder) throws {
            try result.encode(to: encoder)
            var container = encoder.container(keyedBy: AddedKeys.self)
            try container.encode(suppressions, forKey: .suppressions)
            try container.encode(suppressionTotals, forKey: .suppressionTotals)
        }
    }

    /// The run's suppression totals as the summary carries them.
    struct Suppressions: Encodable {
        let acknowledged: Int
        let suppressed: Int
        let baselined: Int
        let acknowledgedByForm: [String: Int]
        let suppressedByForm: [String: Int]
        let byChecker: [String: SuppressionTotals]
        let policy: SuppressionPolicy
        let exclusions: [ActiveExclusion]

        init(ledger: SuppressionLedger, policy: SuppressionPolicy) {
            acknowledged = ledger.overall.acknowledged
            suppressed = ledger.overall.suppressed
            baselined = ledger.overall.baselined
            acknowledgedByForm = ledger.overall.acknowledgedByForm
            suppressedByForm = ledger.overall.suppressedByForm
            var perChecker: [String: SuppressionTotals] = [:]
            for entry in ledger.checkers {
                var totals = perChecker[entry.checkerId] ?? SuppressionTotals()
                totals.add(entry.totals)
                perChecker[entry.checkerId] = totals
            }
            byChecker = perChecker
            self.policy = policy
            exclusions = ledger.exclusions
        }
    }

    struct Summary: Encodable {
        let status: String
        let totalChecks: Int
        let passed: Int
        let failed: Int
        let warnings: Int
        let skipped: Int
        let totalErrors: Int
        let totalWarnings: Int
        let totalDuration: Double
        let suppressions: Suppressions

        init(from results: [CheckResult], strict: Bool, ledger: SuppressionLedger, policy: SuppressionPolicy) {
            suppressions = Suppressions(ledger: ledger, policy: policy)
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
