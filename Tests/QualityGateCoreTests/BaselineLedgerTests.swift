import Foundation
import Testing
@testable import QualityGateCore

/// Phase 4c §3 — the decaying baseline, on the L12 lifecycle machinery.
///
/// Sonar's baseline is institutionalized suppression: old debt never comes
/// due. Ours is a judgment artifact: every record carries a content hash
/// (churn detection), a recorded date, and an expiry — debts age, visibly.
/// All of it is local machinery: a date compare, a hash, a JSON file. No
/// service, no auth, no second writer.
@Suite("BaselineLedger")
struct BaselineLedgerTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a fixture source file and returns its path.
    private func writeSource(_ lines: [String], in dir: URL, named name: String = "Fixture.swift") throws -> String {
        let path = dir.appendingPathComponent(name).path
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func finding(rule: String, file: String, line: Int, severity: Diagnostic.Severity = .error) -> Diagnostic {
        Diagnostic(severity: severity, message: "planted", filePath: file, lineNumber: line, ruleId: rule)
    }

    // MARK: - Adoption & matching

    @Test("adopt records every finding; the same findings then match")
    func adoptThenMatch() throws {
        let dir = try makeSandbox()
        let file = try writeSource(["let a = x!", "let b = y!"], in: dir)
        let findings = [
            finding(rule: "safety.force-unwrap", file: file, line: 1),
            finding(rule: "safety.force-unwrap", file: file, line: 2),
        ]

        let ledger = BaselineLedger.adopt(findings: findings, recordedAt: now, decayDays: 180)
        #expect(ledger.records.count == 2)
        #expect(ledger.records.allSatisfy { $0.expiresAt == now.addingTimeInterval(180 * 86_400) })

        for diagnostic in findings {
            #expect(ledger.disposition(of: diagnostic, now: now) == .baselined(
                expiresAt: now.addingTimeInterval(180 * 86_400)))
        }
    }

    @Test("a new finding is not in the baseline — it gates")
    func newFindingGates() throws {
        let dir = try makeSandbox()
        let file = try writeSource(["let a = x!", "let c = z!"], in: dir)
        let ledger = BaselineLedger.adopt(
            findings: [finding(rule: "safety.force-unwrap", file: file, line: 1)],
            recordedAt: now, decayDays: 180)

        // Line 2 was never adopted.
        let fresh = finding(rule: "safety.force-unwrap", file: file, line: 2)
        #expect(ledger.disposition(of: fresh, now: now) == .new)
    }

    @Test("content churn breaks the match — an edited line's finding gates again")
    func hashDriftGates() throws {
        let dir = try makeSandbox()
        let file = try writeSource(["let a = x!"], in: dir)
        let ledger = BaselineLedger.adopt(
            findings: [finding(rule: "safety.force-unwrap", file: file, line: 1)],
            recordedAt: now, decayDays: 180)

        // The line changes (still violating, but it's *new* judgment territory).
        try ["let a = renamed!"].joined(separator: "\n")
            .write(toFile: file, atomically: true, encoding: .utf8)
        let churned = finding(rule: "safety.force-unwrap", file: file, line: 1)
        #expect(ledger.disposition(of: churned, now: now) == .new)
    }

    @Test("line-number drift does NOT break the match — content is the key")
    func lineDriftStillMatches() throws {
        let dir = try makeSandbox()
        let file = try writeSource(["let a = x!"], in: dir)
        let ledger = BaselineLedger.adopt(
            findings: [finding(rule: "safety.force-unwrap", file: file, line: 1)],
            recordedAt: now, decayDays: 180)

        // Two lines inserted above; same content now at line 3.
        try ["// header", "", "let a = x!"].joined(separator: "\n")
            .write(toFile: file, atomically: true, encoding: .utf8)
        let drifted = finding(rule: "safety.force-unwrap", file: file, line: 3)
        #expect(ledger.disposition(of: drifted, now: now) == .baselined(
            expiresAt: now.addingTimeInterval(180 * 86_400)))
    }

    // MARK: - Decay

    @Test("past expiry, a matched debt is re-verify — it comes due, never silent")
    func expiryMeansReVerify() throws {
        let dir = try makeSandbox()
        let file = try writeSource(["let a = x!"], in: dir)
        let ledger = BaselineLedger.adopt(
            findings: [finding(rule: "safety.force-unwrap", file: file, line: 1)],
            recordedAt: now, decayDays: 30)

        let later = now.addingTimeInterval(31 * 86_400)
        let debt = finding(rule: "safety.force-unwrap", file: file, line: 1)
        #expect(ledger.disposition(of: debt, now: later) == .reVerify(
            expiredAt: now.addingTimeInterval(30 * 86_400)))
    }

    // MARK: - Applying to results

    @Test("apply: baselined findings become notes, new ones keep gating, expired ones warn")
    func applyToResults() throws {
        let dir = try makeSandbox()
        let file = try writeSource(["let a = x!", "let b = y!", "let c = z!"], in: dir)
        // Adopt lines 1 and 2; line 2's record is already expired.
        var ledger = BaselineLedger.adopt(
            findings: [finding(rule: "r", file: file, line: 1)],
            recordedAt: now, decayDays: 180)
        let expired = BaselineLedger.adopt(
            findings: [finding(rule: "r", file: file, line: 2)],
            recordedAt: now.addingTimeInterval(-40 * 86_400), decayDays: 30)
        ledger = BaselineLedger(records: ledger.records + expired.records)

        let result = CheckResult(
            checkerId: "safety",
            status: .failed,
            diagnostics: [
                finding(rule: "r", file: file, line: 1),
                finding(rule: "r", file: file, line: 2),
                finding(rule: "r", file: file, line: 3),
            ],
            duration: .milliseconds(1))

        let applied = BaselineLedger.apply(ledger: ledger, to: [result], now: now)
        let diagnostics = applied.results[0].diagnostics

        // Line 1: baselined → note, origin-tagged, expiry visible.
        #expect(diagnostics[0].severity == .note)
        #expect(diagnostics[0].origin == "baseline")
        #expect(diagnostics[0].message.contains("baselined until"))
        // Line 2: expired → warning, re-verify framing.
        #expect(diagnostics[1].severity == .warning)
        #expect(diagnostics[1].message.contains("baseline EXPIRED"))
        // Line 3: new → untouched, still gates.
        #expect(diagnostics[2].severity == .error)
        #expect(diagnostics[2].origin == nil)

        // The verdict recomputes: an error remains (line 3) → still failed.
        #expect(applied.results[0].status == .failed)
        #expect(applied.summary.baselined == 1)
        #expect(applied.summary.expired == 1)
        #expect(applied.summary.newFindings == 1)
    }

    @Test("apply: a result whose only findings are baselined passes")
    func fullyBaselinedPasses() throws {
        let dir = try makeSandbox()
        let file = try writeSource(["let a = x!"], in: dir)
        let ledger = BaselineLedger.adopt(
            findings: [finding(rule: "r", file: file, line: 1)],
            recordedAt: now, decayDays: 180)
        let result = CheckResult(
            checkerId: "safety",
            status: .failed,
            diagnostics: [finding(rule: "r", file: file, line: 1)],
            duration: .milliseconds(1))
        let applied = BaselineLedger.apply(ledger: ledger, to: [result], now: now)
        #expect(applied.results[0].status == .passed)
    }

    // MARK: - Persistence

    @Test("the ledger round-trips through its JSON file")
    func persistence() throws {
        let dir = try makeSandbox()
        let file = try writeSource(["let a = x!"], in: dir)
        let ledger = BaselineLedger.adopt(
            findings: [finding(rule: "r", file: file, line: 1)],
            recordedAt: now, decayDays: 180)

        let path = dir.appendingPathComponent(".quality-gate-baseline.json").path
        try ledger.save(to: path)
        let loaded = try BaselineLedger.load(from: path)
        #expect(loaded.records == ledger.records)

        #expect(try BaselineLedger.load(from: dir.appendingPathComponent("missing.json").path).records.isEmpty)
    }
}
