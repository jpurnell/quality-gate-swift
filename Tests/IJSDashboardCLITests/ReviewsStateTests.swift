import Foundation
import Testing
@testable import CorpusService
@testable import IJSDashboardCLI

/// Phase 3b §3/§7 — the pending-review surface and the governed
/// acknowledge path.
///
/// Governed rules (policy `requiresSecondReviewer`) never acknowledge in
/// one keystroke: the first identity's acknowledge is HELD, a distinct
/// second identity approves from the Reviews view, and only then does a
/// re-acknowledge write the marker. Witnesses on escape hatches, never
/// silence.
@Suite("Reviews state machine")
struct ReviewsStateTests {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeReview(
        id: String = UUID().uuidString,
        ruleId: String = "safety.force-unwrap",
        justification: String = "guarded upstream",
        state: PendingReview.State = .pending
    ) -> PendingReview {
        PendingReview(
            id: id, ruleId: ruleId, justification: justification,
            submittedBy: "jpurnell", submittedAt: base, state: state)
    }

    // MARK: - Navigation

    @Test("the reviews key opens the Reviews view from the portfolio; escape returns")
    func reviewsViewOpens() {
        var state = DashboardState(projectIDs: ["proj"])
        state.handleInput(.reviews)
        #expect(state.currentView == .reviews)
        state.handleInput(.escape)
        #expect(state.currentView == .portfolio)
    }

    @Test("arrows move the review selection within bounds")
    func reviewNavigation() {
        var state = DashboardState(projectIDs: ["proj"])
        state.setReviewRows([makeReview(), makeReview(), makeReview()])
        state.handleInput(.reviews)
        state.handleInput(.arrowDown)
        state.handleInput(.arrowDown)
        state.handleInput(.arrowDown) // clamped
        #expect(state.selectedReviewIndex == 2)
        state.handleInput(.arrowUp)
        #expect(state.selectedReviewIndex == 1)
    }

    // MARK: - Approve / reject

    @Test("approve on the selected review produces a pending approval request")
    func approveProducesRequest() {
        var state = DashboardState(projectIDs: ["proj"])
        let review = makeReview(id: "r-1")
        state.setReviewRows([review])
        state.handleInput(.reviews)
        state.handleInput(.approve)
        #expect(state.pendingReviewAction == ReviewActionRequest(reviewID: "r-1", action: .approve, reason: nil))
        state.clearPendingReviewAction()
        #expect(state.pendingReviewAction == nil)
    }

    @Test("reject prompts for a reason; confirming produces the rejection request")
    func rejectPromptsForReason() {
        var state = DashboardState(projectIDs: ["proj"])
        state.setReviewRows([makeReview(id: "r-2")])
        state.handleInput(.reviews)
        state.handleInput(.reject)
        #expect(state.isTextEntryActive)
        for ch in "not narrow enough" { state.handleInput(.character(ch)) }
        state.handleInput(.enter)
        #expect(state.pendingReviewAction == ReviewActionRequest(
            reviewID: "r-2", action: .reject, reason: "not narrow enough"))
        #expect(!state.isTextEntryActive)
    }

    @Test("approve with no reviews does nothing")
    func approveEmptyNoop() {
        var state = DashboardState(projectIDs: ["proj"])
        state.handleInput(.reviews)
        state.handleInput(.approve)
        #expect(state.pendingReviewAction == nil)
    }

    // MARK: - Governed acknowledge decision (pure)

    @Test("an ungoverned rule acknowledges immediately")
    func ungovernedWrites() {
        let policy = ReviewPolicy(requiresSecondReviewer: ["safety.*"])
        let action = GovernedAcknowledge.decide(
            policy: policy, reviews: [], ruleId: "idiom.empty-count", reason: "fine")
        #expect(action == .writeMarker)
    }

    @Test("no policy at all acknowledges immediately — solo mode is untouched")
    func noPolicyWrites() {
        let action = GovernedAcknowledge.decide(
            policy: nil, reviews: [], ruleId: "safety.force-unwrap", reason: "fine")
        #expect(action == .writeMarker)
    }

    @Test("a governed rule with no prior review submits and holds")
    func governedSubmits() {
        let policy = ReviewPolicy(requiresSecondReviewer: ["safety.*"])
        let action = GovernedAcknowledge.decide(
            policy: policy, reviews: [], ruleId: "safety.force-unwrap", reason: "guarded upstream")
        #expect(action == .submitForReview)
    }

    @Test("a governed rule with a matching pending review stays held")
    func governedPendingHolds() {
        let policy = ReviewPolicy(requiresSecondReviewer: ["safety.*"])
        let action = GovernedAcknowledge.decide(
            policy: policy,
            reviews: [makeReview(justification: "guarded upstream")],
            ruleId: "safety.force-unwrap", reason: "guarded upstream")
        #expect(action == .awaitingSecondIdentity)
    }

    @Test("a governed rule with a matching APPROVED review writes the marker")
    func governedApprovedWrites() {
        let policy = ReviewPolicy(requiresSecondReviewer: ["safety.*"])
        let approved = makeReview(
            justification: "guarded upstream",
            state: .approved(by: "reviewer", at: base))
        let action = GovernedAcknowledge.decide(
            policy: policy, reviews: [approved],
            ruleId: "safety.force-unwrap", reason: "guarded upstream")
        #expect(action == .writeMarker)
    }

    @Test("a rejected review blocks the acknowledge with the rejection reason")
    func governedRejectedBlocks() {
        let policy = ReviewPolicy(requiresSecondReviewer: ["safety.*"])
        let rejected = makeReview(
            justification: "guarded upstream",
            state: .rejected(by: "reviewer", at: base, reason: "not narrow enough"))
        let action = GovernedAcknowledge.decide(
            policy: policy, reviews: [rejected],
            ruleId: "safety.force-unwrap", reason: "guarded upstream")
        #expect(action == .rejected(by: "reviewer", reason: "not narrow enough"))
    }

    @Test("a different justification is a different judgment — it submits fresh")
    func differentReasonSubmitsFresh() {
        let policy = ReviewPolicy(requiresSecondReviewer: ["safety.*"])
        let approved = makeReview(
            justification: "guarded upstream",
            state: .approved(by: "reviewer", at: base))
        let action = GovernedAcknowledge.decide(
            policy: policy, reviews: [approved],
            ruleId: "safety.force-unwrap", reason: "a different rationale")
        #expect(action == .submitForReview)
    }
}

/// The dashboard's file-level façade over the shared review artifacts —
/// exercised against a temp corpus exactly as the app loop drives it.
@Suite("ReviewStore round-trip", .serialized)
struct ReviewStoreTests {

    private func makeCorpus() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-corpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        requiresSecondReviewer:
          - "safety.*"
        selfAcknowledgeAllowed:
          - "legibility.*"
        """.write(toFile: ReviewStore.policyPath(corpusPath: dir.path), atomically: true, encoding: .utf8)
        return dir.path
    }

    @Test("policy loads from corpus YAML; a corpus without one is solo mode")
    func policyLoads() throws {
        let corpus = try makeCorpus()
        let policy = ReviewStore.policy(corpusPath: corpus)
        #expect(policy?.requiresSecondReviewer(for: "safety.force-unwrap") == true)
        #expect(policy?.requiresSecondReviewer(for: "idiom.empty-count") == false)

        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("bare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        #expect(ReviewStore.policy(corpusPath: bare.path) == nil)
    }

    @Test("submit holds a governed judgment; a distinct identity approves; the submitter cannot")
    func governedLifecycle() throws {
        let corpus = try makeCorpus()
        let submitStatus = ReviewStore.submit(
            corpusPath: corpus, ruleId: "safety.force-unwrap",
            justification: "guarded upstream", by: "jpurnell")
        #expect(submitStatus.contains("Held for review"))

        let pending = ReviewStore.pending(corpusPath: corpus)
        #expect(pending.count == 1)
        let review = try #require(pending.first)

        let selfApprove = ReviewStore.apply(
            ReviewActionRequest(reviewID: review.id, action: .approve, reason: nil),
            corpusPath: corpus, reviewer: "jpurnell")
        #expect(selfApprove.contains("DISTINCT second identity"))
        #expect(ReviewStore.pending(corpusPath: corpus).count == 1)

        let approve = ReviewStore.apply(
            ReviewActionRequest(reviewID: review.id, action: .approve, reason: nil),
            corpusPath: corpus, reviewer: "contributor")
        #expect(approve.contains("Approved safety.force-unwrap"))
        #expect(ReviewStore.pending(corpusPath: corpus).isEmpty)

        // The approved review now unlocks the acknowledge.
        let action = GovernedAcknowledge.decide(
            policy: ReviewStore.policy(corpusPath: corpus),
            reviews: ReviewStore.all(corpusPath: corpus),
            ruleId: "safety.force-unwrap", reason: "guarded upstream")
        #expect(action == .writeMarker)
    }

    @Test("an ungoverned rule submits as accepted, never queues")
    func ungovernedAccepted() throws {
        let corpus = try makeCorpus()
        let status = ReviewStore.submit(
            corpusPath: corpus, ruleId: "idiom.empty-count",
            justification: "fine", by: "jpurnell")
        #expect(status.contains("Accepted without review"))
        #expect(ReviewStore.pending(corpusPath: corpus).isEmpty)
    }
}
