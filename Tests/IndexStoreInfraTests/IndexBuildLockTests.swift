import Foundation
import Synchronization
import Testing
@testable import IndexStoreInfra

@Suite("StoreLocator: index-build lock")
struct IndexBuildLockTests {

    private func tempLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-lock-\(UUID().uuidString).lock")
    }

    @Test("Body runs and the lock is released (re-acquirable)")
    func acquiresAndReleases() throws {
        let lockURL = tempLockURL()
        var ran = false
        try StoreLocator.withExclusiveLock(at: lockURL) { ran = true }
        #expect(ran)
        // Re-acquiring proves the first hold was released.
        var ranAgain = false
        try StoreLocator.withExclusiveLock(at: lockURL) { ranAgain = true }
        #expect(ranAgain)
    }

    @Test("Concurrent holders are serialized — never two in the critical section at once")
    func serializesConcurrentHolders() throws {
        let lockURL = tempLockURL()
        struct Counters: Sendable { var current = 0; var peak = 0 }
        let counters = Mutex(Counters())

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            try? StoreLocator.withExclusiveLock(at: lockURL) {
                counters.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current) }
                Thread.sleep(forTimeInterval: 0.01)  // force an overlap window
                counters.withLock { $0.current -= 1 }
            }
        }

        let peak = counters.withLock { $0.peak }
        #expect(peak == 1)  // flock guarantees mutual exclusion across all 8 workers
    }

    /// A store a peer is still writing looks fresh early: its directory is newer than the
    /// sources, and a unit named `*Tests` appears as soon as the first test file is indexed.
    /// Returning it unlocked handed SwiftCLIKit's scheduled CI a census of 455 units where the
    /// finished build had 500, and `unreachable` reported a symbol whose only caller was in a
    /// module not yet indexed. `ensureFresh` must not return while a build holds the lock.
    @Test("ensureFresh waits for a peer holding the index-build lock, even when the store looks fresh")
    func ensureFreshWaitsForPeerBuild() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("qg-lock-fresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        let source = sources.appendingPathComponent("Thing.swift")
        try Data("struct Thing {}".utf8).write(to: source)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: source.path)
        let units = StoreLocator.unitsDirectory(in: StoreLocator.swiftbuildStorePath(packageRoot: root))
        try fm.createDirectory(at: units, withIntermediateDirectories: true)
        try Data("unit".utf8).write(to: units.appendingPathComponent("ThingTests.swift.o-HASH"))
        let buildPath = StoreLocator.indexBuildDirectory(packageRoot: root)
        try fm.createDirectory(at: buildPath, withIntermediateDirectories: true)
        let lockURL = buildPath.appendingPathComponent(".index-build.lock")

        let held = DispatchSemaphore(value: 0)
        let released = Mutex<Date?>(nil)
        let peer = Thread {
            try? StoreLocator.withExclusiveLock(at: lockURL) {
                held.signal()
                Thread.sleep(forTimeInterval: 0.5)
                released.withLock { $0 = Date() }
            }
        }
        peer.start()
        try #require(held.wait(timeout: .now() + 10) == .success)

        _ = try StoreLocator.ensureFresh(packageRoot: root)
        let returned = Date()

        let releasedAt = try #require(released.withLock { $0 })
        #expect(returned >= releasedAt)
    }
}
