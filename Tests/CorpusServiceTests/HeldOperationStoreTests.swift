import Foundation
import Testing
@testable import CorpusService
import CorpusKit
import QualityGateTypes

/// Phase 3b — the held-operation spool. A governed write that goes `.held`
/// must survive, byte-faithful, until its review is decided: approval lands
/// the original artifact, rejection discards it. Without this, "held,
/// never lost" would be a promise about the review record only — the
/// artifact itself would vanish.
@Suite("HeldOperationStore", .serialized)
struct HeldOperationStoreTests {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStoreDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("held-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMetadataOperation(projectID: String = "fixture") -> CorpusWriteOperation {
        let override = OverrideRecord(
            diagnosticOverride: DiagnosticOverride(
                ruleId: "safety.force-unwrap",
                justification: "guarded upstream",
                filePath: "/tmp/A.swift",
                lineNumber: 3),
            author: "jpurnell",
            riskTier: .safety,
            authorityLevel: .decisionOwner)
        let metadata = CheckResultMetadata(
            projectID: projectID,
            timestamp: base,
            environment: .local,
            decisionOwner: "jpurnell",
            results: [],
            overrides: [override],
            riskTier: .safety,
            ethicalFlags: [],
            consistencyScore: nil)
        return .metadata(metadata, calibrations: [], projectID: projectID)
    }

    @Test("a held operation round-trips through the store, faithful to the artifact")
    func roundTrip() async throws {
        let store = HeldOperationStore(directory: try makeStoreDir())
        try await store.hold(makeMetadataOperation(), forReview: "r-1")

        let loaded = try #require(await store.operation(forReview: "r-1"))
        guard case .metadata(let metadata, _, let projectID) = loaded else {
            Issue.record("expected a metadata operation back")
            return
        }
        #expect(projectID == "fixture")
        #expect(metadata.overrides.first?.diagnosticOverride.ruleId == "safety.force-unwrap")
        #expect(metadata.timestamp == base)
    }

    @Test("held operations survive a store restart — the spool is durable")
    func survivesRestart() async throws {
        let dir = try makeStoreDir()
        try await HeldOperationStore(directory: dir).hold(makeMetadataOperation(), forReview: "r-2")

        let reopened = HeldOperationStore(directory: dir)
        let loaded = try #require(await reopened.operation(forReview: "r-2"))
        guard case .metadata(let metadata, _, let projectID) = loaded else {
            Issue.record("expected a metadata operation back after restart")
            return
        }
        #expect(projectID == "fixture")
        #expect(metadata.decisionOwner == "jpurnell")
    }

    @Test("discard removes exactly the decided review's operation")
    func discardRemoves() async throws {
        let store = HeldOperationStore(directory: try makeStoreDir())
        try await store.hold(makeMetadataOperation(), forReview: "r-3")
        try await store.hold(makeMetadataOperation(projectID: "other"), forReview: "r-4")

        try await store.discard(reviewID: "r-3")
        let gone = await store.operation(forReview: "r-3")
        #expect(gone == nil)
        let kept = try #require(await store.operation(forReview: "r-4"))
        guard case .metadata(_, _, let keptProjectID) = kept else {
            Issue.record("expected the undecided review's metadata operation to survive")
            return
        }
        #expect(keptProjectID == "other")
    }

    @Test("an unknown review id loads nothing")
    func unknownIsNil() async throws {
        let store = HeldOperationStore(directory: try makeStoreDir())
        let loaded = await store.operation(forReview: "never-held")
        #expect(loaded == nil)
    }
}

/// The handler's resolve loop over the spool: approval applies the original
/// operation, rejection discards it, pending waits. The full "held, never
/// lost" contract, end to end.
@Suite("GovernedWriteHandler resolve", .serialized)
struct GovernedResolveTests {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeClone() throws -> String {
        try GitFixture.makeRepo()
    }

    private func makeStoreDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve-held-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeHarness() throws -> (handler: GovernedWriteHandler, clone: String, reviews: ReviewQueue) {
        let clone = try makeClone()
        let reviews = ReviewQueue(storePath: clone + "/pending-reviews.json")
        let handler = GovernedWriteHandler(
            queue: CorpusWriteQueue(workingClone: clone),
            tokens: nil,
            reviews: reviews,
            policy: ReviewPolicy(requiresSecondReviewer: ["safety.*"]),
            heldOperations: HeldOperationStore(directory: try makeStoreDir()))
        return (handler, clone, reviews)
    }

    private func makeGovernedRequest() -> WriteRequest {
        let override = OverrideRecord(
            diagnosticOverride: DiagnosticOverride(
                ruleId: "safety.force-unwrap", justification: "guarded upstream"),
            author: "jpurnell", riskTier: .safety, authorityLevel: .decisionOwner)
        let metadata = CheckResultMetadata(
            projectID: "fixture", timestamp: base, environment: .local,
            decisionOwner: "jpurnell", results: [], overrides: [override],
            riskTier: .safety, ethicalFlags: [], consistencyScore: nil)
        return WriteRequest(
            operation: .metadata(metadata, calibrations: [], projectID: "fixture"),
            assertedOwner: "jpurnell")
    }

    @Test("held → approved by a distinct identity → resolve applies the original artifact")
    func approvedResolves() async throws {
        let (handler, clone, reviews) = try makeHarness()
        let outcome = await handler.handle(makeGovernedRequest(), now: base)
        guard case .held(let review) = outcome else {
            Issue.record("expected the governed write to hold, got \(outcome)")
            return
        }
        // The artifact is provably absent while held.
        let before = try await DirectCorpusTransport().readMetadata(
            from: CorpusPath(basePath: clone, projectID: "fixture"),
            startDate: base.addingTimeInterval(-60), endDate: base.addingTimeInterval(60))
        #expect(before.isEmpty)

        _ = try await reviews.approve(id: review.id, by: "contributor", now: base)
        let resolution = try await handler.resolve(reviewID: review.id, now: base)
        guard case .applied = resolution else {
            Issue.record("expected .applied, got \(resolution)")
            return
        }

        let after = try await DirectCorpusTransport().readMetadata(
            from: CorpusPath(basePath: clone, projectID: "fixture"),
            startDate: base.addingTimeInterval(-60), endDate: base.addingTimeInterval(60))
        #expect(after.count == 1)
        #expect(after.first?.overrides.first?.diagnosticOverride.ruleId == "safety.force-unwrap")
        // The spool entry is consumed.
        let second = try await handler.resolve(reviewID: review.id, now: base)
        #expect(second == .nothingHeld)
    }

    @Test("held → rejected → resolve discards; the artifact never lands")
    func rejectedDiscards() async throws {
        let (handler, clone, reviews) = try makeHarness()
        let outcome = await handler.handle(makeGovernedRequest(), now: base)
        guard case .held(let review) = outcome else {
            Issue.record("expected the governed write to hold, got \(outcome)")
            return
        }
        _ = try await reviews.reject(id: review.id, by: "contributor", reason: "not narrow enough", now: base)
        let resolution = try await handler.resolve(reviewID: review.id, now: base)
        #expect(resolution == .discarded(rejectedBy: "contributor"))

        let artifacts = try await DirectCorpusTransport().readMetadata(
            from: CorpusPath(basePath: clone, projectID: "fixture"),
            startDate: base.addingTimeInterval(-60), endDate: base.addingTimeInterval(60))
        #expect(artifacts.isEmpty)
    }

    @Test("resolve on a still-pending review waits — nothing applied, nothing lost")
    func pendingWaits() async throws {
        let (handler, _, _) = try makeHarness()
        let outcome = await handler.handle(makeGovernedRequest(), now: base)
        guard case .held(let review) = outcome else {
            Issue.record("expected the governed write to hold, got \(outcome)")
            return
        }
        let resolution = try await handler.resolve(reviewID: review.id, now: base)
        #expect(resolution == .stillPending)
        // The held operation is untouched and can still resolve later.
        let again = try await handler.resolve(reviewID: review.id, now: base)
        #expect(again == .stillPending)
    }

    @Test("a handler without a spool behaves exactly as before — held drops to the review record only")
    func noSpoolUnchanged() async throws {
        let clone = try makeClone()
        let handler = GovernedWriteHandler(
            queue: CorpusWriteQueue(workingClone: clone),
            tokens: nil,
            reviews: ReviewQueue(storePath: clone + "/pending-reviews.json"),
            policy: ReviewPolicy(requiresSecondReviewer: ["safety.*"]))
        let outcome = await handler.handle(makeGovernedRequest(), now: base)
        guard case .held(let review) = outcome else {
            Issue.record("expected the governed write to hold, got \(outcome)")
            return
        }
        let resolution = try await handler.resolve(reviewID: review.id, now: base)
        #expect(resolution == .nothingHeld)
    }
}
