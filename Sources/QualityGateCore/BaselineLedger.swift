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

    /// Creates a record.
    public init(ruleId: String, contentHash: String, filePath: String?, recordedAt: Date, expiresAt: Date) {
        self.ruleId = ruleId
        self.contentHash = contentHash
        self.filePath = filePath
        self.recordedAt = recordedAt
        self.expiresAt = expiresAt
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
           let source = try? String(contentsOfFile: path, encoding: .utf8) { // silent: unreadable source falls back to the message hash
            let lines = source.components(separatedBy: "\n")
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
    /// - Parameters:
    ///   - findings: The current findings (notes are ignored — they never gated).
    ///   - recordedAt: Adoption timestamp.
    ///   - decayDays: Days until each debt comes due.
    /// - Returns: The ledger, de-duplicated by match key.
    public static func adopt(findings: [Diagnostic], recordedAt: Date, decayDays: Int) -> BaselineLedger {
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
                filePath: finding.filePath,
                recordedAt: recordedAt,
                expiresAt: recordedAt.addingTimeInterval(Double(decayDays) * 86_400)))
        }
        return BaselineLedger(records: records)
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

    /// Applies the ledger to a run's results.
    ///
    /// Baselined findings become origin-tagged notes with their expiry
    /// visible; expired debts become re-verify warnings; new findings pass
    /// through untouched. Each result's verdict recomputes from what
    /// remains: errors → failed, warnings → warning, else passed.
    public static func apply(
        ledger: BaselineLedger,
        to results: [CheckResult],
        now: Date
    ) -> (results: [CheckResult], summary: Summary) {
        var summary = Summary()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        let transformed = results.map { result -> CheckResult in
            guard result.status == .failed || result.status == .warning else { return result }
            let diagnostics = result.diagnostics.map { diagnostic -> Diagnostic in
                guard diagnostic.severity != .note else { return diagnostic }
                switch ledger.disposition(of: diagnostic, now: now) {
                case .baselined(let expiresAt):
                    summary.baselined += 1
                    return replace(
                        diagnostic, severity: .note,
                        message: "\(diagnostic.message) (baselined until \(dateFormatter.string(from: expiresAt)))")
                case .reVerify(let expiredAt):
                    summary.expired += 1
                    return replace(
                        diagnostic, severity: .warning,
                        message: "\(diagnostic.message) — baseline EXPIRED \(dateFormatter.string(from: expiredAt)); re-verify: extend consciously (re-adopt) or fix")
                case .new:
                    summary.newFindings += 1
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
        return (transformed, summary)
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
