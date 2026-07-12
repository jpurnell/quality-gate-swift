import Foundation
import Testing
@testable import IJSDashboardCLI
@testable import IJSDashboardCore

/// Phase 3a §7 — the workbench state machine: findings inbox navigation,
/// acknowledge-with-reason text entry, and the calibrate wizard.
///
/// The dashboard grows from display to workbench: an advisory finding is
/// acknowledgeable in place (the reason becomes the marker comment), and
/// calibration is human-reachable. All interaction is modeled here, pure;
/// the app loop consumes pending requests.
@Suite("Workbench state machine")
struct WorkbenchStateTests {

    private func makeInboxState() -> DashboardState {
        var state = DashboardState(projectIDs: ["proj"])
        state.handleInput(.enter) // drill into detail
        state.setInboxRows([
            InboxRow(ruleId: "idiom.empty-count", message: "use isEmpty",
                     filePath: "/tmp/A.swift", lineNumber: 3, acknowledgeable: true),
            InboxRow(ruleId: "complexity.cognitive", message: "too clever",
                     filePath: "/tmp/B.swift", lineNumber: 9, acknowledgeable: false),
            InboxRow(ruleId: "smell.god-object", message: "34 members",
                     filePath: "/tmp/C.swift", lineNumber: 1, acknowledgeable: true),
        ])
        // → to Inbox tab (summary → checkers → inbox)
        state.handleInput(.arrowRight)
        state.handleInput(.arrowRight)
        return state
    }

    // MARK: - Tab

    @Test("DetailTab gains the Inbox tab after Checkers")
    func inboxTabExists() {
        #expect(DetailTab.allCases == [.summary, .checkers, .inbox])
        #expect(DetailTab.inbox.label == "Inbox")
    }

    // MARK: - Navigation

    @Test("arrows move the inbox selection within bounds")
    func inboxNavigation() {
        var state = makeInboxState()
        #expect(state.selectedTab == .inbox)
        #expect(state.selectedInboxIndex == 0)
        state.handleInput(.arrowDown)
        #expect(state.selectedInboxIndex == 1)
        state.handleInput(.arrowDown)
        state.handleInput(.arrowDown) // clamped at last
        #expect(state.selectedInboxIndex == 2)
        state.handleInput(.arrowUp)
        #expect(state.selectedInboxIndex == 1)
    }

    // MARK: - Acknowledge flow

    @Test("enter on an acknowledgeable item opens reason entry; typed text lands in the buffer")
    func acknowledgeOpensTextEntry() {
        var state = makeInboxState()
        state.handleInput(.enter)
        #expect(state.isTextEntryActive)
        state.handleInput(.character("o"))
        state.handleInput(.character("k"))
        #expect(state.textEntryBuffer == "ok")
        state.handleInput(.backspace)
        #expect(state.textEntryBuffer == "o")
    }

    @Test("enter on a non-acknowledgeable item does nothing")
    func nonAcknowledgeableIgnored() {
        var state = makeInboxState()
        state.handleInput(.arrowDown) // complexity.cognitive — no marker path
        state.handleInput(.enter)
        #expect(!state.isTextEntryActive)
        #expect(state.pendingAcknowledge == nil)
    }

    @Test("confirming the reason produces a pending acknowledge request and closes entry")
    func acknowledgeConfirm() {
        var state = makeInboxState()
        state.handleInput(.enter)
        for ch in "reviewed: fine" { state.handleInput(.character(ch)) }
        state.handleInput(.enter)
        #expect(state.pendingAcknowledge == AcknowledgeRequest(
            projectID: "proj", itemIndex: 0, reason: "reviewed: fine"))
        #expect(!state.isTextEntryActive)
        state.clearPendingAcknowledge()
        #expect(state.pendingAcknowledge == nil)
    }

    @Test("escape cancels text entry without producing a request")
    func acknowledgeCancel() {
        var state = makeInboxState()
        state.handleInput(.enter)
        state.handleInput(.character("x"))
        state.handleInput(.escape)
        #expect(!state.isTextEntryActive)
        #expect(state.pendingAcknowledge == nil)
        // Still in the detail view — escape consumed by the entry session.
        #expect(state.currentView == .projectDetail)
    }

    @Test("while text entry is active, q is a character, not quit")
    func qIsTypedNotQuit() {
        var state = makeInboxState()
        state.handleInput(.enter)
        state.handleInput(.character("q"))
        #expect(!state.shouldQuit)
        #expect(state.textEntryBuffer == "q")
    }

    // MARK: - Calibrate wizard

    @Test("the calibrate key opens the wizard on its first step from any detail tab")
    func calibrateOpens() {
        var state = DashboardState(projectIDs: ["proj"])
        state.handleInput(.enter)
        state.handleInput(.calibrate)
        #expect(state.isTextEntryActive)
        #expect(state.calibrateStep == .ruleId)
    }

    @Test("each confirmed step advances; the last produces the pending calibration")
    func calibrateWizardCompletes() {
        var state = DashboardState(projectIDs: ["proj"])
        state.handleInput(.enter)
        state.handleInput(.calibrate)
        let answers = ["safety.force-unwrap", "narrow case, guarded upstream",
                       "rushed refactor", "expedient", "design",
                       "guard may be too far away", "2"]
        for answer in answers {
            for ch in answer { state.handleInput(.character(ch)) }
            state.handleInput(.enter)
        }
        let pending = state.pendingCalibration
        #expect(pending?.projectID == "proj")
        #expect(pending?.fields[.ruleId] == "safety.force-unwrap")
        #expect(pending?.fields[.failedStep] == "design")
        #expect(pending?.fields[.riskTier] == "2")
        #expect(!state.isTextEntryActive)
        state.clearPendingCalibration()
        #expect(state.pendingCalibration == nil)
    }

    @Test("escape mid-wizard discards all collected steps")
    func calibrateCancelDiscards() {
        var state = DashboardState(projectIDs: ["proj"])
        state.handleInput(.enter)
        state.handleInput(.calibrate)
        for ch in "safety.x" { state.handleInput(.character(ch)) }
        state.handleInput(.enter)
        state.handleInput(.escape)
        #expect(!state.isTextEntryActive)
        #expect(state.pendingCalibration == nil)
        #expect(state.calibrateStep == nil)
    }

    @Test("an empty required step does not advance the wizard")
    func emptyStepRefused() {
        var state = DashboardState(projectIDs: ["proj"])
        state.handleInput(.enter)
        state.handleInput(.calibrate)
        state.handleInput(.enter) // empty ruleId
        #expect(state.calibrateStep == .ruleId)
        #expect(state.isTextEntryActive)
    }
}
