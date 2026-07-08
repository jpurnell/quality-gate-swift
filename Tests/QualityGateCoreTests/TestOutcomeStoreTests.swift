import Foundation
import Testing
@testable import QualityGateCore

@Suite("TestOutcomeStore: persistence of per-run rosters")
struct TestOutcomeStoreTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-outcome-store-tests")
            .appendingPathComponent(UUID().uuidString)
    }

    private func record(fingerprint: String = "fp", commit: String = "c1") -> TestRunRecord {
        TestRunRecord(
            packageFingerprint: fingerprint,
            commit: commit,
            loadProxy: 1,
            outcomes: [TestOutcome(suite: "S", test: "t", passed: true)]
        )
    }

    @Test("Store then load round-trips the record")
    func storeThenLoad() {
        let store = TestOutcomeStore(directory: tempDir())
        let original = record()
        store.storeLatest(original, key: "pkg")
        #expect(store.loadLatest(key: "pkg") == original)
    }

    @Test("Load on an empty store is nil (no prior data)")
    func loadEmptyIsNil() {
        let store = TestOutcomeStore(directory: tempDir())
        #expect(store.loadLatest(key: "pkg") == nil)
    }

    @Test("A corrupt entry is treated as no prior data, never a crash")
    func corruptEntryIsNil() throws {
        let dir = tempDir()
        let store = TestOutcomeStore(directory: dir)
        store.storeLatest(record(), key: "pkg")
        // Corrupt the on-disk entry.
        let entry = try #require(store.entryURLForTesting(key: "pkg"))
        try Data("not json".utf8).write(to: entry)
        #expect(store.loadLatest(key: "pkg") == nil)
    }

    @Test("Storing again overwrites the previous record")
    func storeOverwrites() {
        let store = TestOutcomeStore(directory: tempDir())
        store.storeLatest(record(commit: "c1"), key: "pkg")
        store.storeLatest(record(commit: "c2"), key: "pkg")
        #expect(store.loadLatest(key: "pkg")?.commit == "c2")
    }

    @Test("Different keys are isolated")
    func keysIsolated() {
        let store = TestOutcomeStore(directory: tempDir())
        store.storeLatest(record(commit: "a"), key: "pkg-a")
        store.storeLatest(record(commit: "b"), key: "pkg-b")
        #expect(store.loadLatest(key: "pkg-a")?.commit == "a")
        #expect(store.loadLatest(key: "pkg-b")?.commit == "b")
    }
}
