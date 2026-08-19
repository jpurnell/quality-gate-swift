import Foundation
import Testing
@testable import QualityGateCore

// MARK: - Test doubles

/// A deterministic fake checker for exercising the runner.
private struct FakeChecker: QualityChecker {
    let id: String
    let name: String
    let summary = "Test double; not a documented checker"
    let category = CheckerCategory.specialty
    let kind = CheckerKind.code
    let effect = CheckerEffect.readOnly
    let executesProjectCode = false
    let status: CheckResult.Status
    let delay: Duration
    /// Optional tracker to record concurrent execution.
    let tracker: ConcurrencyTracker?
    /// If true, throws instead of returning a result.
    let throwsError: Bool
    let isParallelSafe: Bool
    /// If non-nil, the checker opts into caching with these input files.
    let cacheInputFiles: [String]?
    /// Counts how many times `check()` actually executed (to detect cache hits).
    let callCounter: CallCounter?

    init(
        id: String,
        status: CheckResult.Status = .passed,
        delay: Duration = .zero,
        tracker: ConcurrencyTracker? = nil,
        throwsError: Bool = false,
        isParallelSafe: Bool = true,
        cacheInputFiles: [String]? = nil,
        callCounter: CallCounter? = nil
    ) {
        self.id = id
        self.name = id
        self.status = status
        self.delay = delay
        self.tracker = tracker
        self.throwsError = throwsError
        self.isParallelSafe = isParallelSafe
        self.cacheInputFiles = cacheInputFiles
        self.callCounter = callCounter
    }

    struct Boom: Error {}

    func cacheInputs(configuration: Configuration) -> CacheInputs? {
        cacheInputFiles.map { CacheInputs(files: $0) }
    }

    func check(configuration: Configuration) async throws -> CheckResult {
        await callCounter?.increment()
        await tracker?.enter()
        if delay != .zero {
            try? await Task.sleep(for: delay)
        }
        await tracker?.leave()
        if throwsError { throw Boom() }
        return CheckResult(checkerId: id, status: status, diagnostics: [], duration: .zero)
    }
}

/// Records peak concurrency observed across fake checkers.
private actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

/// Counts checker executions.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

// MARK: - Tests

@Suite("CheckerRunner")
struct CheckerRunnerTests {

    @Test("Returns results in checker order regardless of completion order")
    func preservesOrder() async {
        // First checker is slowest, so it finishes last — output must still be A,B,C.
        let checkers: [any QualityChecker] = [
            FakeChecker(id: "A", delay: .milliseconds(80)),
            FakeChecker(id: "B", delay: .milliseconds(10)),
            FakeChecker(id: "C", delay: .milliseconds(40)),
        ]
        let results = await CheckerRunner(maxConcurrency: 4).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true
        )
        #expect(results.map(\.checkerId) == ["A", "B", "C"])
    }

    @Test("Runs all checkers when continueOnFailure is true, even after a failure")
    func runsAllOnContinue() async {
        let checkers: [any QualityChecker] = [
            FakeChecker(id: "A", status: .failed),
            FakeChecker(id: "B", status: .passed),
            FakeChecker(id: "C", status: .passed),
        ]
        let results = await CheckerRunner(maxConcurrency: 4).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true
        )
        #expect(results.count == 3)
    }

    @Test("Applies the transform to every result")
    func appliesTransform() async {
        let checkers: [any QualityChecker] = [
            FakeChecker(id: "A"),
            FakeChecker(id: "B"),
        ]
        let results = await CheckerRunner(maxConcurrency: 4).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true,
            transform: { original in
                CheckResult(checkerId: original.checkerId + "!", status: original.status, diagnostics: [], duration: .zero)
            }
        )
        #expect(results.map(\.checkerId) == ["A!", "B!"])
    }

    @Test("A throwing checker becomes a failed checker-error result")
    func throwingCheckerBecomesFailure() async {
        let checkers: [any QualityChecker] = [
            FakeChecker(id: "boom", throwsError: true),
        ]
        let results = await CheckerRunner(maxConcurrency: 4).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true
        )
        #expect(results.count == 1)
        #expect(results.first?.status == .failed)
        #expect(results.first?.diagnostics.first?.ruleId == "checker-error")
    }

    @Test("Checkers actually run concurrently when the limit allows")
    func runsConcurrently() async {
        let tracker = ConcurrencyTracker()
        let checkers: [any QualityChecker] = (0..<4).map {
            FakeChecker(id: "c\($0)", delay: .milliseconds(60), tracker: tracker)
        }
        _ = await CheckerRunner(maxConcurrency: 8).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true
        )
        let peak = await tracker.peak
        #expect(peak == 4)  // all four overlap under a generous limit
    }

    @Test("Concurrency is bounded by maxConcurrency")
    func boundsConcurrency() async {
        let tracker = ConcurrencyTracker()
        let checkers: [any QualityChecker] = (0..<6).map {
            FakeChecker(id: "c\($0)", delay: .milliseconds(40), tracker: tracker)
        }
        _ = await CheckerRunner(maxConcurrency: 2).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true
        )
        let peak = await tracker.peak
        #expect(peak <= 2)  // never more than the limit in flight
        #expect(peak >= 1)
    }

    @Test("Empty checker list yields empty results")
    func emptyList() async {
        let results = await CheckerRunner(maxConcurrency: 4).run(
            checkers: [],
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true
        )
        #expect(results.isEmpty)
    }

    @Test("Non-parallel-safe checkers never overlap, even under a generous limit")
    func exclusiveCheckersRunSequentially() async {
        let tracker = ConcurrencyTracker()
        let checkers: [any QualityChecker] = (0..<3).map {
            FakeChecker(id: "excl\($0)", delay: .milliseconds(40), tracker: tracker, isParallelSafe: false)
        }
        _ = await CheckerRunner(maxConcurrency: 8).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true
        )
        let peak = await tracker.peak
        #expect(peak == 1)  // exclusive checkers must run strictly one at a time
    }

    @Test("Mixed set: exclusive stay serial while parallel-safe overlap; order preserved")
    func mixedPartitionPreservesOrderAndIsolation() async {
        let exclusiveTracker = ConcurrencyTracker()
        let parallelTracker = ConcurrencyTracker()
        let checkers: [any QualityChecker] = [
            FakeChecker(id: "build", delay: .milliseconds(30), tracker: exclusiveTracker, isParallelSafe: false),
            FakeChecker(id: "safety", delay: .milliseconds(30), tracker: parallelTracker),
            FakeChecker(id: "test", delay: .milliseconds(30), tracker: exclusiveTracker, isParallelSafe: false),
            FakeChecker(id: "recursion", delay: .milliseconds(30), tracker: parallelTracker),
            FakeChecker(id: "complexity", delay: .milliseconds(30), tracker: parallelTracker),
        ]
        let results = await CheckerRunner(maxConcurrency: 8).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true
        )
        // Results come back in original checker order regardless of partition.
        #expect(results.map(\.checkerId) == ["build", "safety", "test", "recursion", "complexity"])
        let exclusivePeak = await exclusiveTracker.peak
        let parallelPeak = await parallelTracker.peak
        #expect(exclusivePeak == 1)   // build + test never overlap
        #expect(parallelPeak == 3)    // safety + recursion + complexity overlap
    }

    @Test("continueOnFailure=false: a failing exclusive checker skips the parallel phase")
    func failingExclusiveSkipsParallel() async {
        let parallelTracker = ConcurrencyTracker()
        let checkers: [any QualityChecker] = [
            FakeChecker(id: "build", status: .failed, isParallelSafe: false),
            FakeChecker(id: "safety", delay: .milliseconds(20), tracker: parallelTracker),
            FakeChecker(id: "recursion", delay: .milliseconds(20), tracker: parallelTracker),
        ]
        let results = await CheckerRunner(maxConcurrency: 8).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: false
        )
        // Only the failing exclusive checker ran; the parallel phase was skipped.
        #expect(results.map(\.checkerId) == ["build"])
        let parallelPeak = await parallelTracker.peak
        #expect(parallelPeak == 0)  // no parallel checker executed
    }
}

// MARK: - Result cache behavior

@Suite("CheckerRunner: result cache")
struct CheckerRunnerCacheTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-runner-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(
        _ checker: FakeChecker, cache: ResultCache, useCache: Bool
    ) async -> [CheckResult] {
        await CheckerRunner(maxConcurrency: 4).run(
            checkers: [checker], configuration: Configuration(),
            strict: false, continueOnFailure: true,
            cache: cache, gateHash: "gate-hash", useCache: useCache
        )
    }

    @Test("Unchanged input across two runs → checker runs once (second is a cache hit)")
    func cacheHitSkipsRerun() async throws {
        let dir = try tempDir()
        let input = dir.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        let cache = ResultCache(directory: dir.appendingPathComponent("cache"))
        let counter = CallCounter()
        let checker = FakeChecker(id: "cacheable", cacheInputFiles: [input.path], callCounter: counter)

        _ = await run(checker, cache: cache, useCache: true)
        _ = await run(checker, cache: cache, useCache: true)

        let count = await counter.count
        #expect(count == 1)  // second run served from cache
    }

    @Test("A changed input file re-runs the checker")
    func changedInputRerunsChecker() async throws {
        let dir = try tempDir()
        let input = dir.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        let cache = ResultCache(directory: dir.appendingPathComponent("cache"))
        let counter = CallCounter()
        let checker = FakeChecker(id: "cacheable", cacheInputFiles: [input.path], callCounter: counter)

        _ = await run(checker, cache: cache, useCache: true)
        try "v2".write(to: input, atomically: true, encoding: .utf8)  // input changed
        _ = await run(checker, cache: cache, useCache: true)

        let count = await counter.count
        #expect(count == 2)  // fingerprint changed → re-run
    }

    @Test("A non-cacheable checker (cacheInputs == nil) runs every time")
    func nonCacheableAlwaysRuns() async throws {
        let dir = try tempDir()
        let cache = ResultCache(directory: dir.appendingPathComponent("cache"))
        let counter = CallCounter()
        let checker = FakeChecker(id: "plain", callCounter: counter)  // no cacheInputFiles → nil

        _ = await run(checker, cache: cache, useCache: true)
        _ = await run(checker, cache: cache, useCache: true)

        let count = await counter.count
        #expect(count == 2)
    }

    @Test("useCache == false bypasses the cache even for a cacheable checker")
    func useCacheFalseBypasses() async throws {
        let dir = try tempDir()
        let input = dir.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        let cache = ResultCache(directory: dir.appendingPathComponent("cache"))
        let counter = CallCounter()
        let checker = FakeChecker(id: "cacheable", cacheInputFiles: [input.path], callCounter: counter)

        _ = await run(checker, cache: cache, useCache: false)
        _ = await run(checker, cache: cache, useCache: false)

        let count = await counter.count
        #expect(count == 2)  // caching disabled → always runs
    }

    @Test("A cached failing result is still surfaced as failing")
    func cachedFailureStillFails() async throws {
        let dir = try tempDir()
        let input = dir.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        let cache = ResultCache(directory: dir.appendingPathComponent("cache"))
        let checker = FakeChecker(id: "cacheable", status: .failed, cacheInputFiles: [input.path])

        _ = await run(checker, cache: cache, useCache: true)          // stores the failure
        let second = await run(checker, cache: cache, useCache: true) // cache hit
        #expect(second.first?.status == .failed)
    }
}
