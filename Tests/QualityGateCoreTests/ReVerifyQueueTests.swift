import Foundation
import Testing
@testable import QualityGateCore

/// Phase 3a §7 — the re-verify queue, L12's interaction surface.
///
/// Expired baseline debts don't vanish and don't silently re-arm: they queue
/// for a conscious decision — re-affirm (re-dated, attributed) or retire
/// (the record goes; if the debt still exists it gates on the next run).
/// Both actions are explicit; nothing is silent, everything ages.
@Suite("BaselineLedger re-verify queue")
struct ReVerifyQueueTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLedger() -> BaselineLedger {
        let live = BaselineRecord(
            ruleId: "safety.force-unwrap", contentHash: "aaa", filePath: "A.swift",
            recordedAt: now.addingTimeInterval(-86_400 * 30),
            expiresAt: now.addingTimeInterval(86_400 * 150))
        let expired = BaselineRecord(
            ruleId: "logging.print", contentHash: "bbb", filePath: "B.swift",
            recordedAt: now.addingTimeInterval(-86_400 * 200),
            expiresAt: now.addingTimeInterval(-86_400 * 20))
        let alsoExpired = BaselineRecord(
            ruleId: "safety.force-try", contentHash: "ccc", filePath: "C.swift",
            recordedAt: now.addingTimeInterval(-86_400 * 200),
            expiresAt: now.addingTimeInterval(-86_400 * 5))
        return BaselineLedger(records: [live, expired, alsoExpired])
    }

    @Test("the queue lists exactly the expired records, oldest expiry first")
    func queueListsExpired() {
        let queue = makeLedger().reVerifyQueue(now: now)
        #expect(queue.map(\.ruleId) == ["logging.print", "safety.force-try"])
    }

    @Test("re-affirm re-dates and attributes the chosen records, leaving others untouched")
    func reAffirm() throws {
        let ledger = makeLedger()
        let updated = ledger.reAffirming(
            contentHashes: ["bbb"], decayDays: 90, now: now, attributedTo: "jpurnell")

        let reAffirmed = try #require(updated.records.first { $0.contentHash == "bbb" })
        #expect(reAffirmed.recordedAt == now)
        #expect(reAffirmed.expiresAt == now.addingTimeInterval(86_400 * 90))
        #expect(reAffirmed.reAffirmedBy == "jpurnell")
        // The other expired record still queues.
        #expect(updated.reVerifyQueue(now: now).map(\.contentHash) == ["ccc"])
        // The live record is untouched.
        let live = try #require(updated.records.first { $0.contentHash == "aaa" })
        #expect(live.reAffirmedBy == nil)
        #expect(live.recordedAt == now.addingTimeInterval(-86_400 * 30))
    }

    @Test("retire removes the chosen records — the finding returns to the gate")
    func retire() {
        let ledger = makeLedger()
        let updated = ledger.retiring(contentHashes: ["bbb", "ccc"])
        #expect(updated.records.count == 1)
        #expect(updated.records.first?.contentHash == "aaa")
        #expect(updated.reVerifyQueue(now: now).isEmpty)
    }

    @Test("reAffirmedBy survives a save/load round-trip and legacy ledgers decode without it")
    func attributionPersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reverify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("ledger.json").path

        let updated = makeLedger().reAffirming(
            contentHashes: ["bbb"], decayDays: 90, now: now, attributedTo: "jpurnell")
        try updated.save(to: path)
        let loaded = try BaselineLedger.load(from: path)
        #expect(loaded.records.first { $0.contentHash == "bbb" }?.reAffirmedBy == "jpurnell")
        #expect(loaded.records.first { $0.contentHash == "aaa" }?.reAffirmedBy == nil)
    }
}
