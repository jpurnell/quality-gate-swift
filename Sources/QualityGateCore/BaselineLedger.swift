import Foundation
import Crypto

/// One recorded debt: a finding that existed when the baseline was adopted.
///
/// The identity is (rule, content hash of the flagged line) — line numbers
/// drift harmlessly, but *editing the line* ends the match: churned code is
/// new judgment territory (the L12 content-hash rule). Every record expires.
public struct BaselineRecord: Sendable, Codable, Equatable {
    /// The rule this debt was recorded against.
    public let ruleId: String
    /// SHA-256 of the rule + the flagged line's trimmed text.
    public let contentHash: String
    /// File path at adoption time (informational; not part of the match key
    /// so file moves don't silently orphan records).
    public let filePath: String?
    /// When the debt was recorded.
    public let recordedAt: Date
    /// When the debt comes due.
    public let expiresAt: Date
    /// Who last consciously extended this debt past an expiry (Phase 3a §7).
    /// Nil for records never re-affirmed; absent in legacy ledgers.
    public let reAffirmedBy: String?

    /// Creates a record.
    public init(
        ruleId: String, contentHash: String, filePath: String?,
        recordedAt: Date, expiresAt: Date, reAffirmedBy: String? = nil
    ) {
        self.ruleId = ruleId
        self.contentHash = contentHash
        self.filePath = filePath
        self.recordedAt = recordedAt
        self.expiresAt = expiresAt
        self.reAffirmedBy = reAffirmedBy
    }

    private enum CodingKeys: String, CodingKey {
        case ruleId, contentHash, filePath, recordedAt, expiresAt, reAffirmedBy
    }

    /// Decodes a record; ledgers written before re-affirmation existed
    /// decode with no attribution.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ruleId = try container.decode(String.self, forKey: .ruleId)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        reAffirmedBy = try container.decodeIfPresent(String.self, forKey: .reAffirmedBy)
    }
}

/// The decaying baseline (Phase 4c §3): Sonar's "new code" ergonomics with
/// the judgment model underneath.
///
/// `adopt` records every existing finding; the gate is green on day one;
/// new findings gate immediately; recorded debts appear as notes with their
/// expiry visible; expiry moves a debt to re-verify — extend consciously or
/// fix. Nothing is silent; everything ages. Local machinery only: a hash, a
/// date compare, a JSON file.
public struct BaselineLedger: Sendable, Equatable {
    /// The recorded debts.
    public let records: [BaselineRecord]

    /// Creates a ledger over records.
    public init(records: [BaselineRecord]) {
        self.records = records
    }

    /// Where a finding stands relative to the baseline.
    public enum Disposition: Sendable, Equatable {
        /// Recorded debt, not yet due — reported as a note.
        case baselined(expiresAt: Date)
        /// Recorded debt past expiry — re-verify: extend consciously or fix.
        case reVerify(expiredAt: Date)
        /// Not in the baseline — gates normally.
        case new
    }

    // MARK: - Hashing

    /// The match key for a finding: SHA-256 over the rule and the flagged
    /// line's trimmed text (read from the file as it exists *now*, which is
    /// exactly how churn breaks a match). Falls back to the message when the
    /// line is unreadable, so hashing never fails.
    public static func contentHash(for diagnostic: Diagnostic) -> String {
        let rule = diagnostic.ruleId ?? ""
        var content = diagnostic.message
        if let path = diagnostic.filePath, let line = diagnostic.lineNumber,
           // Falling back to the message hash is not neutral: the two hashes differ, so a
           // baseline recorded from the line no longer matches the same finding read from
           // the message, and a suppressed diagnostic reappears as new.
           let source = SourceFileReader.read(path, checker: "baseline") {
            let lines = source.lines
            if line >= 1 && line <= lines.count {
                content = lines[line - 1].trimmingCharacters(in: .whitespaces)
            }
        }
        let digest = SHA256.hash(data: Data("\(rule)\u{1F}\(content)".utf8))
        return digest.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    // MARK: - Adoption

    /// Records every gate-relevant finding (errors and warnings) as debt.
    ///
    /// With a `projectRoot`, each record's path is written relative to it. The ledger is
    /// committed, and an absolute path publishes where its author keeps their checkouts —
    /// `/Users/<name>/…` on every record of a public repository. The path is informational:
    /// the hash is computed from the file as the checker reported it, before the path is
    /// shortened, and is the same either way.
    ///
    /// - Parameters:
    ///   - findings: The current findings (notes are ignored — they never gated).
    ///   - recordedAt: Adoption timestamp.
    ///   - decayDays: Days until each debt comes due.
    ///   - projectRoot: The root to record paths relative to. `nil` records them as reported.
    /// - Returns: The ledger, de-duplicated by match key.
    public static func adopt(
        findings: [Diagnostic], recordedAt: Date, decayDays: Int, projectRoot: URL? = nil
    ) -> BaselineLedger {
        var seen: Set<String> = []
        var records: [BaselineRecord] = []
        for finding in findings where finding.severity != .note {
            let hash = contentHash(for: finding)
            let key = "\(finding.ruleId ?? "")\u{1F}\(hash)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            records.append(BaselineRecord(
                ruleId: finding.ruleId ?? "",
                contentHash: hash,
                filePath: recordedPath(finding.filePath, projectRoot: projectRoot),
                recordedAt: recordedAt,
                expiresAt: recordedAt.addingTimeInterval(Double(decayDays) * 86_400)))
        }
        return BaselineLedger(records: records)
    }

    /// The path a record carries for a finding reported at `path`.
    ///
    /// Relative to the root when there is one and the file is inside it. A file outside the
    /// root keeps the path it was reported with: there is no shorter name for it that is true.
    private static func recordedPath(_ path: String?, projectRoot: URL?) -> String? {
        guard let path, let projectRoot else { return path }
        return repoRelativePath(path, projectRoot: projectRoot) ?? path
    }

    // MARK: - Repo-relative paths

    /// `path` relative to `projectRoot`, or `nil` when it is not inside it.
    ///
    /// A path already relative is returned as it is. An absolute one is tried against the root
    /// as given, standardised, and with symlinks resolved — a checker may report
    /// `/private/tmp/…` for a project the shell calls `/tmp/…` — and compared by whole
    /// components, so a sibling directory whose name merely begins with the root's is outside.
    ///
    /// - Parameters:
    ///   - path: The path a checker reported.
    ///   - projectRoot: The root the ledger sits in.
    /// - Returns: The repo-relative path, or `nil` if `path` is absolute and outside the root.
    public static func repoRelativePath(_ path: String, projectRoot: URL) -> String? {
        guard path.hasPrefix("/") else { return path }
        let file = URL(fileURLWithPath: path)
        let candidates: [(file: URL, root: URL)] = [
            (file, projectRoot),
            (file.standardizedFileURL, projectRoot.standardizedFileURL),
            (file.resolvingSymlinksInPath(), projectRoot.resolvingSymlinksInPath()),
        ]
        for candidate in candidates {
            let rootComponents = candidate.root.pathComponents
            let fileComponents = candidate.file.pathComponents
            guard fileComponents.count > rootComponents.count,
                  fileComponents.starts(with: rootComponents) else { continue }
            return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }
        return nil
    }

    /// The outcome of ``relativized(projectRoot:)``.
    public struct Relativization: Sendable, Equatable {
        /// The ledger with every path that could be made repo-relative rewritten.
        public let ledger: BaselineLedger
        /// How many records had their path rewritten.
        public let rewritten: Int
        /// Absolute paths that nothing in this checkout accounts for, left as they were.
        public let unresolved: [String]
    }

    /// The same ledger with each record's path made relative to the project root.
    ///
    /// **Nothing that decides a match is touched.** The match key is (rule, content hash), and
    /// the hash is of the rule and the flagged line's text — the path was never an input to
    /// it. So a rewritten ledger absorbs exactly the findings the original did, and every
    /// `contentHash`, `recordedAt`, `expiresAt` and `reAffirmedBy` comes through as it was.
    ///
    /// An existing ledger may have been recorded somewhere else — another machine, another
    /// clone — so its paths need not begin with this root. Each absolute path is resolved by
    /// the first of these that applies:
    ///
    /// 1. it is inside `projectRoot`;
    /// 2. its longest trailing run of components names a file that exists under
    ///    `projectRoot` — which also reveals the root the ledger was recorded at;
    /// 3. it begins with a root revealed by (2), for a file that has since been deleted.
    ///
    /// A path none of them accounts for is left absolute and reported in
    /// ``Relativization/unresolved``, not guessed at.
    ///
    /// - Parameter projectRoot: The root the ledger sits in.
    /// - Returns: The rewritten ledger, the number of records changed, and what was left.
    public func relativized(projectRoot: URL) -> Relativization {
        var resolved: [Int: String] = [:]
        var recordedRoots: Set<[String]> = []
        var pending: [Int] = []

        for (index, record) in records.enumerated() {
            guard let path = record.filePath, path.hasPrefix("/") else { continue }
            if let relative = Self.repoRelativePath(path, projectRoot: projectRoot) {
                resolved[index] = relative
            } else if let found = Self.existingSuffix(of: path, under: projectRoot) {
                resolved[index] = found.relative
                recordedRoots.insert(found.recordedRoot)
            } else {
                pending.append(index)
            }
        }

        var unresolved: [String] = []
        // Longest first, so a root nested inside another revealed root wins.
        let roots = recordedRoots.sorted { $0.count > $1.count }
        for index in pending {
            guard let path = records[index].filePath else { continue }
            let components = URL(fileURLWithPath: path).pathComponents
            if let root = roots.first(where: { components.count > $0.count && components.starts(with: $0) }) {
                resolved[index] = components.dropFirst(root.count).joined(separator: "/")
            } else {
                unresolved.append(path)
            }
        }

        let rewritten = records.enumerated().map { index, record -> BaselineRecord in
            guard let relative = resolved[index] else { return record }
            return BaselineRecord(
                ruleId: record.ruleId,
                contentHash: record.contentHash,
                filePath: relative,
                recordedAt: record.recordedAt,
                expiresAt: record.expiresAt,
                reAffirmedBy: record.reAffirmedBy)
        }
        return Relativization(
            ledger: BaselineLedger(records: rewritten), rewritten: resolved.count, unresolved: unresolved)
    }

    /// The longest trailing run of `path`'s components that names an existing file under `root`.
    ///
    /// Longest first: `Sources/Kit/Alpha.swift` is tried before `Kit/Alpha.swift` and
    /// `Alpha.swift`, so a file of the same name nearer the root is not mistaken for it.
    private static func existingSuffix(
        of path: String, under root: URL
    ) -> (relative: String, recordedRoot: [String])? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count > 1 else { return nil }
        for dropped in 1..<components.count {
            let relative = components.dropFirst(dropped).joined(separator: "/")
            let candidate = root.appendingPathComponent(relative).path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue {
                return (relative, Array(components.prefix(dropped)))
            }
        }
        return nil
    }

    // MARK: - Matching

    /// Where a finding stands, judged against the ledger *and the file as it
    /// exists now*.
    public func disposition(of diagnostic: Diagnostic, now: Date) -> Disposition {
        let hash = Self.contentHash(for: diagnostic)
        let rule = diagnostic.ruleId ?? ""
        guard let record = records.first(where: { $0.ruleId == rule && $0.contentHash == hash }) else {
            return .new
        }
        return now <= record.expiresAt
            ? .baselined(expiresAt: record.expiresAt)
            : .reVerify(expiredAt: record.expiresAt)
    }

    // MARK: - Applying to results

    /// The counts a run reports about its baseline.
    public struct Summary: Sendable, Equatable {
        /// Debts still covered (reported as notes).
        public var baselined: Int = 0
        /// Debts past expiry (returned as re-verify warnings).
        public var expired: Int = 0
        /// Findings not in the baseline (gating normally).
        public var newFindings: Int = 0

        /// Creates an empty summary.
        public init() {}
    }

    /// The origin every baselined or expired diagnostic carries, and the thing
    /// ``summarise(_:)`` counts. One spelling, so the writer and the reader cannot drift.
    public static let origin = "baseline"

    /// Applies the ledger to **one** result.
    ///
    /// This is the whole of the transform, and it is per-result on purpose: ``CheckerRunner``
    /// applies it through its `transform` hook, which runs *before* the early-exit decision.
    /// Applying the ledger after the run instead — which is what happened until this was
    /// split out — meant the checker holding baselined debt still failed *during* the run and
    /// truncated it, so every checker ordered after it never ran. The ledger then rewrote that
    /// checker's verdict to `.passed`, and the run reported success over an unexamined
    /// majority. Overrides already went through that hook; the ledger does the same kind of
    /// thing and now goes through it too.
    ///
    /// Baselined findings become origin-tagged notes with their expiry visible; expired debts
    /// become re-verify warnings; new findings pass through untouched. The verdict recomputes
    /// from what remains: errors → failed, warnings → warning, else passed.
    ///
    /// - Parameters:
    ///   - result: The result to transform.
    ///   - now: The instant expiry is judged against.
    /// - Returns: The result with baselined diagnostics downgraded and its verdict recomputed.
    public func applying(to result: CheckResult, now: Date) -> CheckResult {
        // Reconciled first, so the status this reads is the one the diagnostics imply. A
        // checker that reports `.passed` while carrying a warning used to be skipped here
        // whole; `adopt` had recorded that warning as debt, and it would now gate under
        // `--strict` with its record unread.
        let result = result.reconciled()
        guard result.status == .failed || result.status == .warning else { return result }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        let diagnostics = result.diagnostics.map { diagnostic -> Diagnostic in
            guard diagnostic.severity != .note else { return diagnostic }
            switch disposition(of: diagnostic, now: now) {
            case .baselined(let expiresAt):
                return Self.replace(
                    diagnostic, severity: .note,
                    message: "\(diagnostic.message) (baselined until \(dateFormatter.string(from: expiresAt)))")
            case .reVerify(let expiredAt):
                return Self.replace(
                    diagnostic, severity: .warning,
                    message: "\(diagnostic.message) — baseline EXPIRED \(dateFormatter.string(from: expiredAt)); re-verify: extend consciously (re-adopt) or fix")
            case .new:
                return diagnostic
            }
        }

        let status: CheckResult.Status
        if diagnostics.contains(where: { $0.severity == .error }) {
            status = .failed
        } else if diagnostics.contains(where: { $0.severity == .warning }) {
            status = .warning
        } else {
            status = .passed
        }
        return CheckResult(
            checkerId: result.checkerId,
            status: status,
            diagnostics: diagnostics,
            overrides: result.overrides,
            complianceRecords: result.complianceRecords,
            duration: result.duration)
    }

    /// The counts a run reports, read back off results the ledger has already transformed.
    ///
    /// Derived rather than accumulated, because a per-result transform runs inside a
    /// `@Sendable` closure and counting across results there would need a lock around numbers
    /// that are already recoverable from the output. A lock for a derived number is the kind of
    /// thing that later reads as load-bearing and is not.
    ///
    /// What each count reads: a **baselined** debt is a note carrying ``origin``; an **expired**
    /// one is a warning carrying it; a **new finding** is anything still gating — not a note,
    /// and not ours.
    ///
    /// - Parameter results: Results already passed through ``applying(to:now:)``.
    /// - Returns: The summary for this run.
    public static func summarise(_ results: [CheckResult]) -> Summary {
        var summary = Summary()
        for diagnostic in results.flatMap(\.diagnostics) {
            let isOurs = diagnostic.origin == Self.origin
            switch (isOurs, diagnostic.severity) {
            case (true, .note):     summary.baselined += 1
            case (true, .warning):  summary.expired += 1
            case (false, .note):    break
            default:                summary.newFindings += 1
            }
        }
        return summary
    }

    /// Applies the ledger to a run's results.
    ///
    /// Retained for callers that hold every result already — `adopt`, the SARIF writer, the
    /// tests. The gate itself no longer uses it: it applies ``applying(to:now:)`` through the
    /// runner's transform so the early-exit decision sees the baseline, then calls
    /// ``summarise(_:)``. Both paths are the same two functions in the same order, so they
    /// cannot disagree.
    public static func apply(
        ledger: BaselineLedger,
        to results: [CheckResult],
        now: Date
    ) -> (results: [CheckResult], summary: Summary) {
        let transformed = results.map { ledger.applying(to: $0, now: now) }
        return (transformed, summarise(transformed))
    }

    /// Rebuilds a diagnostic with baseline severity/message and provenance.
    private static func replace(
        _ diagnostic: Diagnostic, severity: Diagnostic.Severity, message: String
    ) -> Diagnostic {
        Diagnostic(
            severity: severity,
            message: message,
            filePath: diagnostic.filePath,
            lineNumber: diagnostic.lineNumber,
            columnNumber: diagnostic.columnNumber,
            ruleId: diagnostic.ruleId,
            suggestedFix: diagnostic.suggestedFix,
            origin: "baseline")
    }

    // MARK: - Re-verify queue (Phase 3a §7 — L12's interaction surface)

    /// The records past expiry, oldest expiry first — the debts awaiting a
    /// conscious decision.
    public func reVerifyQueue(now: Date) -> [BaselineRecord] {
        records.filter { $0.expiresAt <= now }.sorted { $0.expiresAt < $1.expiresAt }
    }

    /// Re-affirms the chosen debts: re-dated to now, expiry pushed out by
    /// the decay window, and attributed — extending a debt is a judgment,
    /// and judgments carry names. Records not chosen are untouched.
    public func reAffirming(
        contentHashes: Set<String>,
        decayDays: Int,
        now: Date,
        attributedTo person: String
    ) -> BaselineLedger {
        let updated = records.map { record -> BaselineRecord in
            guard contentHashes.contains(record.contentHash) else { return record }
            return BaselineRecord(
                ruleId: record.ruleId,
                contentHash: record.contentHash,
                filePath: record.filePath,
                recordedAt: now,
                expiresAt: now.addingTimeInterval(Double(decayDays) * 86_400),
                reAffirmedBy: person)
        }
        return BaselineLedger(records: updated)
    }

    /// Retires the chosen debts: the records go, and any finding they were
    /// covering returns to the gate on the next run.
    public func retiring(contentHashes: Set<String>) -> BaselineLedger {
        BaselineLedger(records: records.filter { !contentHashes.contains($0.contentHash) })
    }

    // MARK: - Persistence

    /// Saves the ledger as deterministic pretty JSON.
    public func save(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Loads a ledger; a missing file is an empty ledger, not an error.
    public static func load(from path: String) throws -> BaselineLedger {
        guard FileManager.default.fileExists(atPath: path) else { // SAFETY: read-only existence check
            return BaselineLedger(records: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return BaselineLedger(records: try decoder.decode([BaselineRecord].self, from: data))
    }
}
