import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// The most fragile assumption in the design, tested directly.
///
/// §5.5 of the proposal carries the whole rollout on `quality-gate adopt`: existing drift
/// becomes dated debt, the gate is green on day one, and only *new* drift gates. That is only
/// true if the ledger can tell one row of a stale region from another. It is stated there as
/// the assumption most likely to be wrong, with per-row findings as the fallback — and it is
/// wrong, which is why the findings are per row.
@Suite("Baseline Adoption")
struct BaselineAdoptionTests {

    private static func enumSource(cases: [(name: String, abstract: String)]) -> String {
        var text = "public enum QualityGateError: Error {\n"
        for entry in cases {
            text += "\n    /// \(entry.abstract)\n    case \(entry.name)(String)\n"
        }
        return text + "}\n"
    }

    private static func project(cases: [(name: String, abstract: String)]) throws -> URL {
        try TemporaryDocProject.make(
            masterPlan: """
            <!-- generated:error-registry -->
            <!-- /generated:error-registry -->
            """,
            extras: ["Sources/QualityGateCore/QualityGateError.swift": enumSource(cases: cases)])
    }

    private static func findings(_ root: URL) async throws -> [Diagnostic] {
        try await DocGeneratedAuditor().check(
            projectRoot: root, configuration: TemporaryDocProject.configuration())
            .diagnostics.filter { $0.severity != .note }
    }

    @Test("Adopted debt stays baselined while a newly drifted row gates immediately")
    func newDriftGatesWhileDebtIsBaselined() async throws {
        let root = try Self.project(cases: [
            ("alpha", "The first error."),
            ("beta", "The second error."),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let adopted = try await Self.findings(root)
        #expect(adopted.count == 2)
        let ledger = BaselineLedger.adopt(
            findings: adopted, recordedAt: Date(), decayDays: 180)
        #expect(ledger.records.count == 2)

        // A third case ships. Its row is drift that nobody adopted.
        try Self.enumSource(cases: [
            ("alpha", "The first error."),
            ("beta", "The second error."),
            ("gamma", "The third error."),
        ]).write(
            to: root.appendingPathComponent("Sources/QualityGateCore/QualityGateError.swift"),
            atomically: true, encoding: .utf8)

        let now = Date()
        let after = try await Self.findings(root)
        #expect(after.count == 3)

        let dispositions = after.map { ledger.disposition(of: $0, now: now) }
        let gating = dispositions.filter { $0 == .new }
        #expect(gating.count == 1)
        #expect(dispositions.filter { if case .baselined = $0 { return true } else { return false } }.count == 2)
    }

    @Test("Debt comes due on a date, and an expired record returns as re-verify")
    func debtExpires() async throws {
        let root = try Self.project(cases: [("alpha", "The first error.")])
        defer { try? FileManager.default.removeItem(at: root) }

        let recordedAt = Date(timeIntervalSince1970: 0)
        let ledger = BaselineLedger.adopt(
            findings: try await Self.findings(root), recordedAt: recordedAt, decayDays: 180)

        let beforeDue = recordedAt.addingTimeInterval(179 * 86_400)
        let afterDue = recordedAt.addingTimeInterval(181 * 86_400)
        let finding = try #require(try await Self.findings(root).first)

        #expect(ledger.disposition(of: finding, now: beforeDue) != .new)
        if case .reVerify = ledger.disposition(of: finding, now: afterDue) {
            // Expected.
        } else {
            Issue.record("an expired debt must return as re-verify, not stay baselined")
        }
    }

    @Test("A region-anchored finding could not decay, which is why findings are per row")
    func regionAnchoredFindingsWouldCollapse() throws {
        // `BaselineLedger.contentHash` hashes the rule plus *the flagged line as it exists in
        // the file now*, and falls back to the message only when there is no readable line.
        // One finding per region, anchored at the opening delimiter, would therefore hash the
        // delimiter — a line that never changes — so every row of a 29-row roster would share
        // one record, adopting it would cover drift that had not happened yet, and the 63rd
        // module would arrive already baselined.
        let root = try TemporaryDocProject.make(masterPlan: """
        <!-- generated:error-registry -->
        <!-- /generated:error-registry -->
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.appendingPathComponent("project/master_plan.md").path
        let anchored = { (message: String) in
            BaselineLedger.contentHash(for: Diagnostic(
                severity: .error, message: message, filePath: path, lineNumber: 1,
                ruleId: "doc-generated.region-stale"))
        }
        #expect(anchored("row A is missing") == anchored("row B is missing"))

        // A finding with no line number hashes its message instead, so one row is one debt.
        let unanchored = { (message: String) in
            BaselineLedger.contentHash(for: Diagnostic(
                severity: .error, message: message, filePath: path,
                ruleId: "doc-generated.region-missing-line"))
        }
        #expect(unanchored("row A is missing") != unanchored("row B is missing"))
    }

    @Test("A missing-line finding's identity survives edits elsewhere in the document")
    func missingLineIdentityIsStable() async throws {
        // Its hash is the message, so the message must not carry a line number: inserting a
        // paragraph above the region would otherwise orphan every recorded debt at once.
        let root = try Self.project(cases: [("alpha", "The first error.")])
        defer { try? FileManager.default.removeItem(at: root) }

        let before = try #require(try await Self.findings(root).first)
        let hashBefore = BaselineLedger.contentHash(for: before)

        let plan = root.appendingPathComponent("project/master_plan.md")
        let shifted = "# A new heading nobody asked for\n\n"
            + (try String(contentsOf: plan, encoding: .utf8))
        try shifted.write(to: plan, atomically: true, encoding: .utf8)

        let after = try #require(try await Self.findings(root).first)
        #expect(BaselineLedger.contentHash(for: after) == hashBefore)
    }
}
