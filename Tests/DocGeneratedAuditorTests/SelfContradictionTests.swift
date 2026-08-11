import Foundation
import Testing
@testable import DocGeneratedAuditor

/// The one rule in this checker that needs no source of truth at all.
///
/// A document asserting P and ¬P about one named artifact is wrong regardless of which side
/// is true, so no generator has to exist for the finding to be sound. It ships first for
/// exactly that reason.
@Suite("Self-Contradiction")
struct SelfContradictionTests {

    // MARK: - The measured case

    @Test("One item, unchecked in one section and checked in another, is a contradiction")
    func opposingTickBoxes() {
        // The shape measured in this repository's own master plan: `XcodeReporter` appears
        // under Current Status as incomplete and under the Phase 4 roadmap as complete.
        let document = """
        ### What's Working
        - [ ] XcodeReporter — `--format xcode` for Xcode Build Phase inline annotations

        ### Phase 4
        - [x] XcodeReporter — `--format xcode` output for Xcode Build Phase inline annotations
        """

        let found = SelfContradictionRule.contradictions(in: document)

        #expect(found.count == 1)
        #expect(found.first?.label == "XcodeReporter")
        #expect(found.first?.incompleteLines == [2])
        #expect(found.first?.completeLines == [5])
    }

    @Test("The finding names both line numbers, because either side may be the wrong one")
    func namesBothSides() {
        let document = "- [x] Alpha — done\n- [ ] Alpha — not done\n"
        guard let found = SelfContradictionRule.contradictions(in: document).first else {
            Issue.record("expected a contradiction")
            return
        }
        #expect(found.message.contains("2"))
        #expect(found.message.contains("1"))
        #expect(found.ruleId == "doc-generated.self-contradiction")
    }

    // MARK: - What is not a contradiction

    @Test("The same item listed twice with the same state is duplication, not contradiction")
    func agreeingDuplicatesAreNotContradictions() {
        #expect(SelfContradictionRule.contradictions(in: "- [x] Alpha\n- [x] Alpha — again\n").isEmpty)
    }

    @Test("Two different items are never a contradiction, however similar their descriptions")
    func differentLabels() {
        let document = """
        - [ ] AlphaAuditor — call-graph cycle detection
        - [x] BetaAuditor — call-graph cycle detection
        """
        #expect(SelfContradictionRule.contradictions(in: document).isEmpty)
    }

    @Test("A struck-through item is history, and history does not contradict the present")
    func struckItemsAreExcluded() {
        // `CLAUDE.md` requires completed roadmap items to be struck through rather than
        // deleted, with the reasoning recorded at the time. That deliberately leaves a
        // completed item and its live successor side by side; reading the pair as a
        // contradiction would punish the housekeeping rule for being followed.
        let document = """
        - [x] ~~Alpha~~ — superseded, kept for the reasoning
        - [ ] Alpha — the replacement, still open
        """
        #expect(SelfContradictionRule.contradictions(in: document).isEmpty)
    }

    @Test("Checklist syntax inside a fenced code block is an example, not a claim")
    func fencedChecklistIsIgnored() {
        let document = """
        ```markdown
        - [ ] Alpha
        - [x] Alpha
        ```
        """
        #expect(SelfContradictionRule.contradictions(in: document).isEmpty)
    }

    // MARK: - Label extraction

    @Test("The label is the artifact name, not the description that follows the dash")
    func labelStopsAtTheSeparator() {
        let items = ChecklistParser.items(in: "- [x] P3b: IJS MCP Server — four tools\n")
        #expect(items.first?.label == "P3b")
    }

    @Test("Backticks and emphasis around a label do not make it a different artifact")
    func labelIsNormalized() {
        let document = "- [ ] `XcodeReporter` — pending\n- [x] **XcodeReporter** — shipped\n"
        #expect(SelfContradictionRule.contradictions(in: document).count == 1)
    }

    @Test("A colon inside a value is not a separator unless whitespace follows it")
    func colonWithoutSpaceIsNotASeparator() {
        let items = ChecklistParser.items(in: "- [ ] Deploy to roseclub.org:8083\n")
        #expect(items.first?.label == "Deploy to roseclub.org:8083")
    }
}
