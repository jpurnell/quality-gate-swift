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
}
