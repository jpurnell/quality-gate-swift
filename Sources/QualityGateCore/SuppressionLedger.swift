import Foundation

/// How many findings did not gate, and under what authority.
public struct SuppressionTotals: Sendable, Codable, Equatable {
    /// Findings silenced by a marker or entry whose reason was validated.
    public var acknowledged: Int
    /// Findings silenced or downgraded by a marker or entry nobody validated.
    public var suppressed: Int
    /// Findings covered by the decaying baseline ledger.
    public var baselined: Int
    /// ``acknowledged``, by the form that did it.
    public var acknowledgedByForm: [String: Int]
    /// ``suppressed``, by the form that did it.
    public var suppressedByForm: [String: Int]

    /// Creates totals; all zero by default.
    public init(
        acknowledged: Int = 0, suppressed: Int = 0, baselined: Int = 0,
        acknowledgedByForm: [String: Int] = [:], suppressedByForm: [String: Int] = [:]
    ) {
        self.acknowledged = acknowledged
        self.suppressed = suppressed
        self.baselined = baselined
        self.acknowledgedByForm = acknowledgedByForm
        self.suppressedByForm = suppressedByForm
    }

    /// Whether nothing was acknowledged, suppressed or baselined.
    public var isEmpty: Bool { acknowledged == 0 && suppressed == 0 && baselined == 0 }

    mutating func count(_ record: SuppressionRecord) {
        switch record.kind {
        case .acknowledged:
            acknowledged += record.hidden
            acknowledgedByForm[record.form, default: 0] += record.hidden
        case .suppressed:
            suppressed += record.hidden
            suppressedByForm[record.form, default: 0] += record.hidden
        }
    }

    mutating func add(_ other: SuppressionTotals) {
        acknowledged += other.acknowledged
        suppressed += other.suppressed
        baselined += other.baselined
        acknowledgedByForm.merge(other.acknowledgedByForm, uniquingKeysWith: +)
        suppressedByForm.merge(other.suppressedByForm, uniquingKeysWith: +)
    }
}

/// A configured exclusion that was in force for this run.
///
/// An exclusion differs from a silenced finding in what is known about it. A marker sits on a
/// finding the checker computed and then declined to raise, so the finding can be named. A
/// path excluded from the walk was never read: what it would have raised is not knowable
/// without doing the work the exclusion exists to skip. So an exclusion reports what *is*
/// cheap to know — that it is active, what it lists, and how many files it matched where the
/// walk already counts them — and is kept out of the finding totals rather than guessed into
/// them.
public struct ActiveExclusion: Sendable, Codable, Equatable {
    /// The configuration key, e.g. `excludePatterns` or `logging.allowedSilentTryFunctions`.
    public let form: String
    /// The configured entries.
    public let entries: [String]
    /// How many `.swift` files the exclusion matched this run, when that is known.
    public let matchedFiles: Int?
    /// One line saying what the exclusion does, for a human summary.
    public let detail: String

    /// Creates an exclusion record.
    public init(form: String, entries: [String], matchedFiles: Int? = nil, detail: String) {
        self.form = form
        self.entries = entries
        self.matchedFiles = matchedFiles
        self.detail = detail
    }
}

/// Everything a run was told not to raise, gathered for reporting.
///
/// Built from the results a reporter is about to print, so it is a function of the output
/// and cannot disagree with it. In particular it is the same on a cache replay as on the run
/// that filled the cache: the records travel in `CheckResult.overrides`, which the cache
/// stores, and the configuration records are added per run by ``OverrideProcessor`` after the
/// cache is read.
public struct SuppressionLedger: Sendable, Equatable {

    /// One checker's records and totals.
    public struct Entry: Sendable, Equatable {
        /// The checker.
        public let checkerId: String
        /// Its records, with per-file duplicate reasons already lowered to suppressions.
        public let records: [SuppressionRecord]
        /// Its totals.
        public let totals: SuppressionTotals
    }

    /// One entry per result, in result order — including checkers that silenced nothing.
    public let checkers: [Entry]
    /// The sum over ``checkers``.
    public let overall: SuppressionTotals
    /// Configured exclusions in force for the run.
    public let exclusions: [ActiveExclusion]

    /// Gathers the ledger for a run.
    ///
    /// - Parameters:
    ///   - results: The results being reported.
    ///   - exclusions: Configured exclusions in force for the run.
    public init(results: [CheckResult], exclusions: [ActiveExclusion] = []) {
        var entries: [Entry] = []
        var overall = SuppressionTotals()
        for result in results {
            let records = Self.records(of: result)
            var totals = SuppressionTotals()
            for record in records { totals.count(record) }
            totals.baselined = result.diagnostics.filter {
                $0.origin == BaselineLedger.origin && $0.severity == .note
            }.count
            overall.add(totals)
            entries.append(Entry(checkerId: result.checkerId, records: records, totals: totals))
        }
        self.checkers = entries
        self.overall = overall
        self.exclusions = exclusions
    }

    /// The overrides a run writes to the judgement corpus.
    ///
    /// Plain overrides, without the envelope, for the records that are forwarded — see
    /// ``SuppressionRecord/forwardedToCorpus`` for which those are and why the rest wait.
    ///
    /// - Parameter results: A run's results.
    /// - Returns: The overrides telemetry sends, in result and override order.
    public static func corpusOverrides(from results: [CheckResult]) -> [DiagnosticOverride] {
        results.flatMap(\.overrides)
            .map(SuppressionRecord.init)
            .filter(\.forwardedToCorpus)
            .map(\.corpusOverride)
    }

    /// A result's records, with the per-file duplicate rule applied.
    ///
    /// A reason that validates on its own is still not a reason when it is the sentence
    /// already written on another marker in the same file: the second copy was pasted, not
    /// decided. The first marker keeps its acknowledgement and each later one is lowered,
    /// naming the line it repeats. Only reasons judged by
    /// ``SuppressionRecord/reasonQualityValidator`` are re-examined — a checker that
    /// validates its own form has its own duplicate rule and has already applied it. Two
    /// findings under one marker share a marker line and are one reason, not a repeat.
    ///
    /// - Parameter result: A checker's result.
    /// - Returns: Its records, in override order.
    public static func records(of result: CheckResult) -> [SuppressionRecord] {
        var firstUse: [String: Int] = [:]
        return result.overrides.map { override in
            let record = SuppressionRecord(override)
            guard record.kind == .acknowledged,
                  record.validator == SuppressionRecord.reasonQualityValidator,
                  let file = record.filePath,
                  let markerLine = record.markerLine ?? record.lineNumber else {
                return record
            }
            let key = file + "\u{0}" + record.reason.lowercased()
            guard let earlier = firstUse[key] else {
                firstUse[key] = markerLine
                return record
            }
            guard earlier != markerLine else { return record }
            return record.rejected(because: "repeats the reason on line \(earlier) of this file")
        }
    }
}

// MARK: - The ratchet

/// What a run does about a suppression — the opt-in half of *zero unvalidated markers*.
///
/// `suppressions:` in `.quality-gate.yml`. The default is ``note``: suppressions are counted
/// and listed and nothing gates, because the day this shipped the portfolio held roughly a
/// thousand unvalidated markers and turning every one into a warning at once would have
/// reddened nearly every repository on the same deploy — a wall, where the point is a
/// ratchet. A repository sets ``warn`` or ``error`` once its count is zero, and from then on a
/// new bare marker is a finding.
public enum SuppressionPolicy: String, Sendable, Codable, Equatable, CaseIterable {
    /// Count and list suppressions; gate on nothing. The default.
    case note
    /// Each suppression is a warning, so it gates under `--strict`.
    case warn
    /// Each suppression is an error.
    case error

    /// Creates a policy by decoding `note`, `warn`, `warning` or `error`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let written = try container.decode(String.self)
        switch written.lowercased() {
        case "note": self = .note
        case "warn", "warning": self = .warn
        case "error": self = .error
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "suppressions: '\(written)' is not one of note, warn, error")
        }
    }
}

/// Turns a result's suppressions into findings, when the repository has asked for that.
public enum SuppressionRatchet {

    /// The rule id of the finding raised for a suppression under `suppressions: warn|error`.
    public static let ruleID = "gate.unvalidated-suppression"

    /// Applies `policy` to one result.
    ///
    /// Per result, so it can run in ``CheckerRunner``'s transform and be seen by the
    /// early-stop decision like any other finding. Idempotent: findings it raised on an
    /// earlier pass are replaced, not added to.
    ///
    /// - Parameters:
    ///   - result: A checker's result, after overrides and the baseline.
    ///   - policy: The repository's policy.
    /// - Returns: The result, with one finding per suppressed record under `warn` or `error`.
    public static func apply(to result: CheckResult, policy: SuppressionPolicy) -> CheckResult {
        let severity: Diagnostic.Severity
        switch policy {
        case .note: return result
        case .warn: severity = .warning
        case .error: severity = .error
        }
        let raised = SuppressionLedger.records(of: result)
            .filter { $0.kind == .suppressed }
            .map { record in
                Diagnostic(
                    severity: severity,
                    message: message(for: record),
                    filePath: record.filePath,
                    lineNumber: record.markerLine ?? record.lineNumber,
                    ruleId: ruleID,
                    suggestedFix: record.source == .configuration
                        ? "Fix the finding and remove the entry from the configuration."
                        : "Fix the finding, or state a specific reason of at least eight words after the marker.")
            }
        guard !raised.isEmpty else { return result }
        let kept = result.diagnostics.filter { $0.ruleId != ruleID }
        return CheckResult(
            checkerId: result.checkerId,
            status: result.status,
            diagnostics: kept + raised,
            overrides: result.overrides,
            complianceRecords: result.complianceRecords,
            duration: result.duration
        ).reconciled()
    }

    static func message(for record: SuppressionRecord) -> String {
        guard record.source != .configuration else {
            // A configuration entry: the "reason" is the entry itself, and there is nothing
            // to say about its wording — configuration has no validated form.
            var text = "configuration silences \(record.ruleId) without a validated reason: \(record.reason)"
            if record.hidden > 1 { text += " — \(record.hidden) findings" }
            return text
        }
        var text = "`\(record.form)` silences \(record.ruleId) without a validated reason"
        if let rejection = record.rejection { text += " (\(rejection))" }
        if !record.reason.isEmpty { text += ": \"\(record.reason)\"" }
        return text
    }
}
