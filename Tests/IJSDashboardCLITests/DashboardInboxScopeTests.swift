import Testing
import Foundation
@testable import IJSDashboardCLI
import IJSDashboardCore
@testable import IJSSensor
import CorpusKit
import QualityGateTypes

/// The drill-down inbox must reflect each checker's latest *standard* run —
/// never a single partial or advisory run read as the whole project state.
/// These pin the composite scoping introduced alongside `ProjectSummary`'s
/// composite gate status.
@Suite("Dashboard inbox scope")
struct DashboardInboxScopeTests {

    @Test("A newer subset run does not hide an older checker's advisory findings")
    func subsetRunKeepsOtherCheckerFindings() {
        // Full run: legibility carries a note; build is clean.
        // A later subset run re-runs only build — it must not blank legibility.
        let runs = [
            makeRun(index: 0, scope: .full, checkerNotes: [
                "legibility": [note(rule: "legibility:reserved", file: "A.swift", line: 3)],
                "build": [],
            ]),
            makeRun(index: 1, scope: .subset(checkers: ["build"]), checkerNotes: [
                "build": [],
            ]),
        ]
        let inbox = DashboardLoader.inboxFindings(fromLatestOf: runs)
        #expect(inbox.count == 1)
        #expect(inbox.first?.ruleID == "legibility:reserved")
    }

    @Test("Advisory surveys never populate the inbox")
    func advisoryRunsExcluded() {
        // A standard run is clean; a later advisory survey downgrades a real
        // finding to a note. That note must not appear as an acknowledgeable item.
        let runs = [
            makeRun(index: 0, scope: .full, checkerNotes: ["safety": []]),
            makeRun(index: 1, scope: .full, gateMode: .advisory, checkerNotes: [
                "safety": [note(rule: "no-force-unwrap", file: "B.swift", line: 9)],
            ]),
        ]
        let inbox = DashboardLoader.inboxFindings(fromLatestOf: runs)
        #expect(inbox.isEmpty)
    }

    @Test("A resolved finding in a newer standard run clears the inbox")
    func newerCleanRunClearsFinding() {
        let runs = [
            makeRun(index: 0, scope: .full, checkerNotes: [
                "legibility": [note(rule: "legibility:reserved", file: "A.swift", line: 3)],
            ]),
            makeRun(index: 1, scope: .subset(checkers: ["legibility"]), checkerNotes: [
                "legibility": [],
            ]),
        ]
        let inbox = DashboardLoader.inboxFindings(fromLatestOf: runs)
        #expect(inbox.isEmpty)
    }
}

// MARK: - Helpers

private func note(rule: String, file: String, line: Int) -> Diagnostic {
    Diagnostic(severity: .note, message: "advisory", filePath: file, lineNumber: line, ruleId: rule)
}

private func makeRun(
    index: Int,
    scope: RunScope,
    gateMode: GateMode = .standard,
    checkerNotes: [String: [Diagnostic]]
) -> TimestampedRun {
    // Advisory notes don't gate, so every result passes; the inbox is driven
    // by the note diagnostics, not the pass/fail status.
    let results = checkerNotes.map { checkerId, diagnostics in
        CheckResult(
            checkerId: checkerId,
            status: .passed,
            diagnostics: diagnostics,
            duration: .milliseconds(10)
        )
    }
    return TimestampedRun(
        metadata: CheckResultMetadata(
            projectID: "test",
            timestamp: Date(timeIntervalSince1970: Double(1_747_267_200 + index * 3600)),
            environment: .local,
            decisionOwner: "test",
            results: results,
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil,
            runScope: scope,
            gateMode: gateMode
        )
    )
}
