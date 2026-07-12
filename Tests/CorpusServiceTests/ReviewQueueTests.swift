import Foundation
import Testing
@testable import CorpusService

/// Phase 3b §3 — the governed-escape-hatch state machine.
///
/// A governed override without a distinct second verified identity is held,
/// never silently accepted, never lost. Solo mode (no policy) is today's
/// behavior exactly.
@Suite("ReviewQueue")
struct ReviewQueueTests {

    private let submittedAt = Date(timeIntervalSince1970: 1_752_000_000)
    private let reviewedAt = Date(timeIntervalSince1970: 1_752_003_600)

    private let policy = ReviewPolicy(
        requiresSecondReviewer: ["safety.*"],
        selfAcknowledgeAllowed: ["legibility.*"])

    private func makeStorePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-service-tests-\(UUID().uuidString)")
            .appendingPathComponent("reviews.json")
            .path
    }

    private func submitHeld(
        _ queue: ReviewQueue,
        ruleId: String = "safety.force-unwrap",
        by identity: String = "jordan",
        at date: Date? = nil
    ) async throws -> PendingReview? {
        let disposition = try await queue.submit(
            ruleId: ruleId,
            justification: "vetted by hand",
            by: identity,
            policy: policy,
            now: date ?? submittedAt)
        guard case .held(let review) = disposition else { return nil }
        return review
    }

    @Test("no policy at all is solo passthrough — accepted")
    func absentPolicyIsAccepted() async throws {
        let queue = ReviewQueue(storePath: makeStorePath())
        let disposition = try await queue.submit(
            ruleId: "safety.force-unwrap",
            justification: "vetted by hand",
            by: "jordan",
            policy: nil,
            now: submittedAt)
        #expect(disposition == .accepted)
        let pending = await queue.pending()
        #expect(pending == [])
    }

    @Test("a self-acknowledgeable rule is accepted")
    func selfAcknowledgeableIsAccepted() async throws {
        let queue = ReviewQueue(storePath: makeStorePath())
        let disposition = try await queue.submit(
            ruleId: "legibility.long-name",
            justification: "advisory only",
            by: "jordan",
            policy: policy,
            now: submittedAt)
        #expect(disposition == .accepted)
    }

    @Test("a governed rule is held as a pending review")
    func governedRuleIsHeld() async throws {
        let queue = ReviewQueue(storePath: makeStorePath())
        guard let review = try await submitHeld(queue) else {
            Issue.record("expected .held for a safety.* rule")
            return
        }
        #expect(review.ruleId == "safety.force-unwrap")
        #expect(review.justification == "vetted by hand")
        #expect(review.submittedBy == "jordan")
        #expect(review.submittedAt == submittedAt)
        #expect(review.state == .pending)
    }

    @Test("a held item round-trips through the store file")
    func heldItemRoundTripsThroughFile() async throws {
        let path = makeStorePath()
        let held: PendingReview?
        do {
            let queue = ReviewQueue(storePath: path)
            held = try await submitHeld(queue)
        }
        guard let held else {
            Issue.record("expected .held for a safety.* rule")
            return
        }

        let reopened = ReviewQueue(storePath: path)
        let pending = await reopened.pending()
        #expect(pending == [held])
    }

    @Test("the submitter cannot approve their own review")
    func approveBySubmitterThrows() async throws {
        let queue = ReviewQueue(storePath: makeStorePath())
        guard let review = try await submitHeld(queue) else {
            Issue.record("expected .held for a safety.* rule")
            return
        }
        await #expect(throws: ReviewQueueError.secondIdentityRequired(review.id)) {
            _ = try await queue.approve(id: review.id, by: "jordan", now: self.reviewedAt)
        }
    }

    @Test("the submitter cannot reject their own review either")
    func rejectBySubmitterThrows() async throws {
        let queue = ReviewQueue(storePath: makeStorePath())
        guard let review = try await submitHeld(queue) else {
            Issue.record("expected .held for a safety.* rule")
            return
        }
        await #expect(throws: ReviewQueueError.secondIdentityRequired(review.id)) {
            _ = try await queue.reject(
                id: review.id, by: "jordan", reason: "changed my mind", now: self.reviewedAt)
        }
    }

    @Test("a distinct second identity approves — recorded transition")
    func approveByDistinctIdentityTransitions() async throws {
        let path = makeStorePath()
        let queue = ReviewQueue(storePath: path)
        guard let review = try await submitHeld(queue) else {
            Issue.record("expected .held for a safety.* rule")
            return
        }
        let approved = try await queue.approve(id: review.id, by: "sam", now: reviewedAt)
        #expect(approved.id == review.id)
        #expect(approved.state == .approved(by: "sam", at: reviewedAt))

        // The transition persists and leaves the pending queue.
        let reopened = ReviewQueue(storePath: path)
        let pending = await reopened.pending()
        #expect(pending == [])
    }

    @Test("reject records the reviewer and the reason")
    func rejectRecordsReason() async throws {
        let queue = ReviewQueue(storePath: makeStorePath())
        guard let review = try await submitHeld(queue) else {
            Issue.record("expected .held for a safety.* rule")
            return
        }
        let rejected = try await queue.reject(
            id: review.id, by: "sam", reason: "justification too thin", now: reviewedAt)
        #expect(rejected.state == .rejected(
            by: "sam", at: reviewedAt, reason: "justification too thin"))
    }

    @Test("approving a non-pending review throws")
    func doubleApproveThrows() async throws {
        let queue = ReviewQueue(storePath: makeStorePath())
        guard let review = try await submitHeld(queue) else {
            Issue.record("expected .held for a safety.* rule")
            return
        }
        _ = try await queue.approve(id: review.id, by: "sam", now: reviewedAt)
        await #expect(throws: ReviewQueueError.notPending(review.id)) {
            _ = try await queue.approve(id: review.id, by: "alex", now: self.reviewedAt)
        }
    }

    @Test("rejecting a non-pending review throws")
    func rejectAfterApproveThrows() async throws {
        let queue = ReviewQueue(storePath: makeStorePath())
        guard let review = try await submitHeld(queue) else {
            Issue.record("expected .held for a safety.* rule")
            return
        }
        _ = try await queue.approve(id: review.id, by: "sam", now: reviewedAt)
        await #expect(throws: ReviewQueueError.notPending(review.id)) {
            _ = try await queue.reject(
                id: review.id, by: "alex", reason: "late", now: self.reviewedAt)
        }
    }

    @Test("approving an unknown id throws")
    func approveUnknownIdThrows() async throws {
        let queue = ReviewQueue(storePath: makeStorePath())
        await #expect(throws: ReviewQueueError.unknownReview("no-such-id")) {
            _ = try await queue.approve(id: "no-such-id", by: "sam", now: self.reviewedAt)
        }
    }

    @Test("pending lists oldest first")
    func pendingIsOldestFirst() async throws {
        let queue = ReviewQueue(storePath: makeStorePath())
        let later = try await submitHeld(
            queue, ruleId: "safety.force-cast", by: "jordan",
            at: submittedAt.addingTimeInterval(600))
        let earlier = try await submitHeld(
            queue, ruleId: "safety.force-unwrap", by: "jordan", at: submittedAt)
        guard let later, let earlier else {
            Issue.record("expected both submissions to be held")
            return
        }

        let pending = await queue.pending()
        #expect(pending.map(\.id) == [earlier.id, later.id])
    }
}
