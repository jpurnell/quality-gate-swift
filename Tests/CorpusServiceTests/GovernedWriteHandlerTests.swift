import CorpusKit
import Foundation
import QualityGateTypes
import Testing
@testable import CorpusService

/// Phase 3b §1 — the validation pipeline in front of the write queue:
/// authenticated request → validation → queue.
///
/// Auth is on when auth exists (a configured TokenStore rejects missing or
/// unverifiable tokens); solo mode passes asserted identity through; a
/// governed override without a distinct second identity is held, and the
/// artifact does not reach the queue until approved.
@Suite("GovernedWriteHandler")
struct GovernedWriteHandlerTests {

    private let now = Date(timeIntervalSince1970: 1_752_000_000)
    private let reviewedAt = Date(timeIntervalSince1970: 1_752_003_600)

    private let safetyPolicy = ReviewPolicy(
        requiresSecondReviewer: ["safety.*"],
        selfAcknowledgeAllowed: ["legibility.*"])

    private func makeStorePath(_ file: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("governed-write-handler-tests-\(UUID().uuidString)")
            .appendingPathComponent(file)
            .path
    }

    private func makeMetadata(
        projectID: String = "demo-project",
        overrides: [OverrideRecord] = []
    ) -> CheckResultMetadata {
        CheckResultMetadata(
            projectID: projectID,
            timestamp: now,
            environment: .local,
            decisionOwner: "jordan",
            results: [],
            overrides: overrides,
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil)
    }

    private func makeSafetyOverride() -> OverrideRecord {
        OverrideRecord(
            diagnosticOverride: DiagnosticOverride(
                ruleId: "safety.force-unwrap",
                justification: "vetted by hand"),
            author: "jordan",
            riskTier: .safety,
            authorityLevel: .decisionOwner)
    }

    private func makeHandler(
        clone: String,
        tokens: TokenStore?,
        policy: ReviewPolicy?
    ) -> (handler: GovernedWriteHandler, queue: CorpusWriteQueue, reviews: ReviewQueue) {
        let queue = CorpusWriteQueue(workingClone: clone)
        let reviews = ReviewQueue(storePath: makeStorePath("reviews.json"))
        let handler = GovernedWriteHandler(
            queue: queue, tokens: tokens, reviews: reviews, policy: policy)
        return (handler, queue, reviews)
    }

    private func artifactDirectoryExists(in clone: String) -> Bool {
        FileManager.default.fileExists(atPath: clone + "/telemetry/demo-project")
    }

    @Test("a configured token store rejects a missing or unverifiable token")
    func configuredTokensRejectBadToken() async throws {
        let clone = try GitFixture.makeRepo()
        let tokens = TokenStore(storePath: makeStorePath("tokens.json"))
        _ = try await tokens.issue(name: "jordan", now: now)
        let fixture = makeHandler(clone: clone, tokens: tokens, policy: nil)
        let operation = CorpusWriteOperation.metadata(
            makeMetadata(), calibrations: [], projectID: "demo-project")

        let missing = await fixture.handler.handle(
            WriteRequest(operation: operation, token: nil, assertedOwner: "jordan"),
            now: now)
        guard case .rejected(let missingReason) = missing else {
            Issue.record("expected .rejected for a missing token, got \(missing)")
            return
        }
        #expect(missingReason.contains("token"))

        let bogus = await fixture.handler.handle(
            WriteRequest(operation: operation, token: "bogus", assertedOwner: "jordan"),
            now: now)
        guard case .rejected = bogus else {
            Issue.record("expected .rejected for an unverifiable token, got \(bogus)")
            return
        }

        // Nothing reached the working clone.
        #expect(!artifactDirectoryExists(in: clone))
    }

    @Test("a verified token is accepted with the token's identity in the envelope")
    func verifiedTokenIsAccepted() async throws {
        let clone = try GitFixture.makeRepo()
        let tokens = TokenStore(storePath: makeStorePath("tokens.json"))
        let token = try await tokens.issue(name: "jordan", now: now)
        let fixture = makeHandler(clone: clone, tokens: tokens, policy: nil)
        let operation = CorpusWriteOperation.metadata(
            makeMetadata(), calibrations: [], projectID: "demo-project")

        let outcome = await fixture.handler.handle(
            WriteRequest(operation: operation, token: token, assertedOwner: "jordan"),
            now: now)
        guard case .accepted(let receipt, let identity) = outcome else {
            Issue.record("expected .accepted for a verified token, got \(outcome)")
            return
        }
        #expect(receipt.sequence == 1)
        #expect(identity.verifiedIdentity == "jordan")
        #expect(identity.assertedOwner == "jordan")
    }

    @Test("solo mode (no token store) passes asserted identity through")
    func soloModePassthrough() async throws {
        let clone = try GitFixture.makeRepo()
        let fixture = makeHandler(clone: clone, tokens: nil, policy: nil)
        let operation = CorpusWriteOperation.metadata(
            makeMetadata(), calibrations: [], projectID: "demo-project")

        let outcome = await fixture.handler.handle(
            WriteRequest(
                operation: operation,
                token: nil,
                assertedOwner: "jordan",
                assertedHost: "mac-studio"),
            now: now)
        guard case .accepted(let receipt, let identity) = outcome else {
            Issue.record("expected .accepted in solo mode, got \(outcome)")
            return
        }
        #expect(receipt.sequence == 1)
        #expect(identity.verifiedIdentity == nil)
        #expect(identity.assertedOwner == "jordan")
        #expect(identity.assertedHost == "mac-studio")

        // The artifact was applied to the working clone.
        let artifacts = try await DirectCorpusTransport().readMetadata(
            from: CorpusPath(basePath: clone, projectID: "demo-project"),
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(60))
        #expect(artifacts.count == 1)
    }

    @Test("a governed safety override is held — artifact stays out of the clone")
    func governedOverrideIsHeld() async throws {
        let clone = try GitFixture.makeRepo()
        let fixture = makeHandler(clone: clone, tokens: nil, policy: safetyPolicy)
        let operation = CorpusWriteOperation.metadata(
            makeMetadata(overrides: [makeSafetyOverride()]),
            calibrations: [],
            projectID: "demo-project")

        let outcome = await fixture.handler.handle(
            WriteRequest(operation: operation, token: nil, assertedOwner: "jordan"),
            now: now)
        guard case .held(let review) = outcome else {
            Issue.record("expected .held for a governed safety override, got \(outcome)")
            return
        }
        #expect(review.ruleId == "safety.force-unwrap")
        #expect(review.justification == "vetted by hand")
        #expect(review.submittedBy == "jordan")
        #expect(review.state == .pending)

        // The artifact did NOT reach the queue or the clone.
        #expect(!artifactDirectoryExists(in: clone))

        // The review is recorded in the queue, visible and never lost.
        let pending = await fixture.reviews.pending()
        #expect(pending == [review])
    }

    @Test("the same governed op with no policy is accepted — solo behavior exactly")
    func governedOpWithoutPolicyIsAccepted() async throws {
        let clone = try GitFixture.makeRepo()
        let fixture = makeHandler(clone: clone, tokens: nil, policy: nil)
        let operation = CorpusWriteOperation.metadata(
            makeMetadata(overrides: [makeSafetyOverride()]),
            calibrations: [],
            projectID: "demo-project")

        let outcome = await fixture.handler.handle(
            WriteRequest(operation: operation, token: nil, assertedOwner: "jordan"),
            now: now)
        guard case .accepted(let receipt, _) = outcome else {
            Issue.record("expected .accepted with no policy, got \(outcome)")
            return
        }
        #expect(receipt.sequence == 1)

        let artifacts = try await DirectCorpusTransport().readMetadata(
            from: CorpusPath(basePath: clone, projectID: "demo-project"),
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(60))
        #expect(artifacts.count == 1)
    }

    @Test("applyApproved lands the held artifact after a second identity approves")
    func applyApprovedLandsTheArtifact() async throws {
        let clone = try GitFixture.makeRepo()
        let fixture = makeHandler(clone: clone, tokens: nil, policy: safetyPolicy)
        let operation = CorpusWriteOperation.metadata(
            makeMetadata(overrides: [makeSafetyOverride()]),
            calibrations: [],
            projectID: "demo-project")

        let outcome = await fixture.handler.handle(
            WriteRequest(operation: operation, token: nil, assertedOwner: "jordan"),
            now: now)
        guard case .held(let review) = outcome else {
            Issue.record("expected .held before approval, got \(outcome)")
            return
        }

        let approved = try await fixture.reviews.approve(
            id: review.id, by: "sam", now: reviewedAt)
        let receipt = try await fixture.handler.applyApproved(approved, operation: operation)
        #expect(receipt.sequence == 1)

        let artifacts = try await DirectCorpusTransport().readMetadata(
            from: CorpusPath(basePath: clone, projectID: "demo-project"),
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(60))
        #expect(artifacts.count == 1)
        #expect(artifacts.first?.projectID == "demo-project")
    }

    @Test("applyApproved refuses a review that was never approved")
    func applyApprovedRefusesPendingReview() async throws {
        let clone = try GitFixture.makeRepo()
        let fixture = makeHandler(clone: clone, tokens: nil, policy: safetyPolicy)
        let operation = CorpusWriteOperation.metadata(
            makeMetadata(overrides: [makeSafetyOverride()]),
            calibrations: [],
            projectID: "demo-project")

        let outcome = await fixture.handler.handle(
            WriteRequest(operation: operation, token: nil, assertedOwner: "jordan"),
            now: now)
        guard case .held(let review) = outcome else {
            Issue.record("expected .held before approval, got \(outcome)")
            return
        }

        await #expect(throws: GovernedWriteError.reviewNotApproved(review.id)) {
            _ = try await fixture.handler.applyApproved(review, operation: operation)
        }
        #expect(!artifactDirectoryExists(in: clone))
    }

    @Test("a projectID mismatch between operation and artifact is rejected")
    func projectIDMismatchIsRejected() async throws {
        let clone = try GitFixture.makeRepo()
        let fixture = makeHandler(clone: clone, tokens: nil, policy: nil)

        let mismatched = CorpusWriteOperation.metadata(
            makeMetadata(projectID: "alpha"), calibrations: [], projectID: "beta")
        let outcome = await fixture.handler.handle(
            WriteRequest(operation: mismatched, token: nil, assertedOwner: "jordan"),
            now: now)
        guard case .rejected(let reason) = outcome else {
            Issue.record("expected .rejected for a projectID mismatch, got \(outcome)")
            return
        }
        #expect(reason.contains("alpha"))
        #expect(reason.contains("beta"))

        let empty = CorpusWriteOperation.metadata(
            makeMetadata(projectID: ""), calibrations: [], projectID: "")
        let emptyOutcome = await fixture.handler.handle(
            WriteRequest(operation: empty, token: nil, assertedOwner: "jordan"),
            now: now)
        guard case .rejected(let emptyReason) = emptyOutcome else {
            Issue.record("expected .rejected for an empty projectID, got \(emptyOutcome)")
            return
        }
        #expect(emptyReason.contains("non-empty"))

        let mismatchedSkip = CorpusWriteOperation.skip(
            SkipRecord(
                projectID: "alpha",
                timestamp: now,
                issueReference: "https://issues.invalid/2",
                author: "jordan",
                environment: .local),
            projectID: "beta")
        let skipOutcome = await fixture.handler.handle(
            WriteRequest(operation: mismatchedSkip, token: nil, assertedOwner: "jordan"),
            now: now)
        guard case .rejected = skipOutcome else {
            Issue.record("expected .rejected for a skip projectID mismatch, got \(skipOutcome)")
            return
        }

        #expect(!artifactDirectoryExists(in: clone))
    }
}
