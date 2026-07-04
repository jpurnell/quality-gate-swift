import Foundation
import Testing
@testable import IndexStoreInfra

private actor Counter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Suite("KeyedAsyncCache")
struct KeyedAsyncCacheTests {

    @Test("Concurrent calls for the same key construct the value exactly once")
    func dedupsConcurrentConstruction() async throws {
        let cache = KeyedAsyncCache<Int>()
        let counter = Counter()

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await cache.value(for: "same-key") {
                        await counter.increment()
                        try? await Task.sleep(for: .milliseconds(30))
                        return 42
                    }
                }
            }
            var all: [Int] = []
            for try await value in group { all.append(value) }
            return all
        }

        #expect(results.count == 20)
        #expect(results.allSatisfy { $0 == 42 })
        let constructions = await counter.count
        #expect(constructions == 1)  // one shared construction, not 20
    }

    @Test("Distinct keys construct once each; repeat hits the cache")
    func perKeyCachingAndReuse() async throws {
        let cache = KeyedAsyncCache<String>()
        let counter = Counter()

        let a = try await cache.value(for: "a") { await counter.increment(); return "A" }
        let b = try await cache.value(for: "b") { await counter.increment(); return "B" }
        let aAgain = try await cache.value(for: "a") { await counter.increment(); return "A-rebuilt" }

        #expect(a == "A")
        #expect(b == "B")
        #expect(aAgain == "A")  // cached value, not rebuilt
        let constructions = await counter.count
        #expect(constructions == 2)  // once for "a", once for "b"
    }

    @Test("A throwing construction is not cached and the next call retries")
    func failuresAreNotCached() async throws {
        struct Boom: Error {}
        let cache = KeyedAsyncCache<Int>()
        let counter = Counter()

        await #expect(throws: Boom.self) {
            try await cache.value(for: "k") {
                await counter.increment()
                throw Boom()
            }
        }
        let recovered = try await cache.value(for: "k") {
            await counter.increment()
            return 7
        }

        #expect(recovered == 7)
        let constructions = await counter.count
        #expect(constructions == 2)  // failure did not poison the cache
    }
}
