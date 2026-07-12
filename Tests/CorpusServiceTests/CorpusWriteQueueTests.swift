import CorpusKit
import Foundation
import Testing
@testable import CorpusService

/// Phase 3b §1 — the single-writer heart of corpusd.
///
/// Concurrent enqueues produce strictly ordered sequence numbers and
/// immediately applied artifacts; a flush is exactly one commit over
/// everything applied since the last flush, pushed only when an `origin`
/// remote exists. Push races and merge commits end by construction.
@Suite("CorpusWriteQueue")
struct CorpusWriteQueueTests {

    private let base = Date(timeIntervalSince1970: 1_752_000_000)

    private func makeMetadata(
        projectID: String = "demo-project",
        timestamp: Date
    ) -> CheckResultMetadata {
        CheckResultMetadata(
            projectID: projectID,
            timestamp: timestamp,
            environment: .local,
            decisionOwner: "jordan",
            results: [],
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil)
    }

    @Test("20 concurrent enqueues produce strictly ordered receipts and applied artifacts")
    func concurrentEnqueuesAreStrictlyOrdered() async throws {
        let clone = try GitFixture.makeRepo()
        let queue = CorpusWriteQueue(workingClone: clone)
        let base = self.base

        let receipts = try await withThrowingTaskGroup(of: QueuedReceipt.self) { group in
            for index in 0..<20 {
                let metadata = makeMetadata(timestamp: base.addingTimeInterval(Double(index)))
                group.addTask {
                    try await queue.enqueue(
                        .metadata(metadata, calibrations: [], projectID: "demo-project"))
                }
            }
            var collected: [QueuedReceipt] = []
            for try await receipt in group {
                collected.append(receipt)
            }
            return collected
        }

        // Strictly ordered: exactly the sequence numbers 1...20, no gaps,
        // no duplicates.
        #expect(receipts.count == 20)
        #expect(Set(receipts.map(\.sequence)) == Set(1...20))

        // Every artifact was applied to the working clone immediately —
        // readable back through the transport.
        let artifacts = try await DirectCorpusTransport().readMetadata(
            from: CorpusPath(basePath: clone, projectID: "demo-project"),
            startDate: base.addingTimeInterval(-60),
            endDate: base.addingTimeInterval(60))
        #expect(artifacts.count == 20)
    }

    @Test("flush is exactly one commit with the batch message and no merges")
    func flushCreatesSingleCommit() async throws {
        let clone = try GitFixture.makeRepo()
        let queue = CorpusWriteQueue(workingClone: clone)

        _ = try await queue.enqueue(
            .metadata(makeMetadata(timestamp: base), calibrations: [], projectID: "demo-project"))
        _ = try await queue.enqueue(
            .workEvent(
                WorkEvent(
                    date: base,
                    commitSHA: "abc123",
                    commitSubjects: ["feat: initial"],
                    changelogDelta: nil,
                    sessionSummary: nil),
                projectID: "demo-project"))
        _ = try await queue.enqueue(
            .skip(
                SkipRecord(
                    projectID: "demo-project",
                    timestamp: base,
                    issueReference: "https://issues.invalid/1",
                    author: "jordan",
                    environment: .local),
                projectID: "demo-project"))

        let result = try await queue.flush()
        #expect(result.operationCount == 3)

        let head = try GitFixture.git(["rev-parse", "HEAD"], cwd: clone)
        #expect(result.commitSHA == head)

        let commitCount = try GitFixture.git(["rev-list", "--count", "HEAD"], cwd: clone)
        #expect(commitCount == "1")

        let subject = try GitFixture.git(["log", "-1", "--format=%s"], cwd: clone)
        #expect(subject == "corpusd: batch 1 ops 1..3")

        let merges = try GitFixture.git(["log", "--merges", "--oneline"], cwd: clone)
        #expect(merges.isEmpty)

        // A second batch numbers itself and its op range correctly.
        _ = try await queue.enqueue(
            .metadata(
                makeMetadata(timestamp: base.addingTimeInterval(120)),
                calibrations: [],
                projectID: "demo-project"))
        let second = try await queue.flush()
        #expect(second.operationCount == 1)
        let secondSubject = try GitFixture.git(["log", "-1", "--format=%s"], cwd: clone)
        #expect(secondSubject == "corpusd: batch 2 ops 4..4")
        let totalCommits = try GitFixture.git(["rev-list", "--count", "HEAD"], cwd: clone)
        #expect(totalCommits == "2")
    }

    @Test("flush pushes to origin when the remote exists — bare HEAD matches the clone")
    func flushPushesToOrigin() async throws {
        let root = try GitFixture.makeTempDir()
        let bare = root + "/origin.git"
        try GitFixture.git(["init", "-q", "--bare", bare], cwd: root)
        let clone = root + "/clone"
        try GitFixture.git(["clone", "-q", "file://" + bare, clone], cwd: root)

        let queue = CorpusWriteQueue(workingClone: clone)
        _ = try await queue.enqueue(
            .metadata(makeMetadata(timestamp: base), calibrations: [], projectID: "demo-project"))
        let result = try await queue.flush()

        let bareHead = try GitFixture.git(["rev-parse", "HEAD"], cwd: bare)
        #expect(result.commitSHA == bareHead)
        #expect(result.operationCount == 1)
    }

    @Test("a nothing-dirty flush returns nil SHA and creates no commit")
    func nothingDirtyFlushIsANoOp() async throws {
        let clone = try GitFixture.makeRepo()
        let queue = CorpusWriteQueue(workingClone: clone)

        let result = try await queue.flush()
        #expect(result.operationCount == 0)
        #expect(result.commitSHA == nil)

        let commitCount = try GitFixture.git(["rev-list", "--all", "--count"], cwd: clone)
        #expect(commitCount == "0")
    }

    @Test("a rejected push surfaces a typed error and never auto-merges")
    func rejectedPushSurfacesTypedError() async throws {
        let root = try GitFixture.makeTempDir()
        let bare = root + "/origin.git"
        try GitFixture.git(["init", "-q", "--bare", bare], cwd: root)
        let cloneA = root + "/clone-a"
        try GitFixture.git(["clone", "-q", "file://" + bare, cloneA], cwd: root)
        let cloneB = root + "/clone-b"
        try GitFixture.git(["clone", "-q", "file://" + bare, cloneB], cwd: root)

        // Another clone advances origin first — the queue's push must be
        // rejected, never auto-merged.
        try "rival artifact\n".write(
            toFile: cloneB + "/rival.txt", atomically: true, encoding: .utf8)
        try GitFixture.git(["add", "-A"], cwd: cloneB)
        try GitFixture.git(
            [
                "-c", "user.name=rival",
                "-c", "user.email=rival@quality-gate.invalid",
                "commit", "-qm", "rival: advance origin",
            ],
            cwd: cloneB)
        try GitFixture.git(["push", "-q", "origin", "HEAD"], cwd: cloneB)

        let queue = CorpusWriteQueue(workingClone: cloneA)
        _ = try await queue.enqueue(
            .metadata(makeMetadata(timestamp: base), calibrations: [], projectID: "demo-project"))

        do {
            _ = try await queue.flush()
            Issue.record("expected the rejected push to throw")
        } catch let error as CorpusWriteQueueError {
            guard case .pushRejected = error else {
                Issue.record("expected .pushRejected, got \(error)")
                return
            }
        }

        // The local batch commit exists, and no merge commit was created.
        let commitCount = try GitFixture.git(["rev-list", "--count", "HEAD"], cwd: cloneA)
        #expect(commitCount == "1")
        let merges = try GitFixture.git(["log", "--merges", "--oneline"], cwd: cloneA)
        #expect(merges.isEmpty)
    }
}
