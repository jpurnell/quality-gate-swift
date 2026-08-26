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
        ).results
        #expect(results.map(\.checkerId) == ["A", "B", "C"])
    }

    @Test("A truncated run names the stop and lists every unreached checker")
    func truncatedRunReportsUnreached() async {
        // Sequential (non-parallel-safe) checkers give a deterministic stop point.
        let checkers: [any QualityChecker] = [
            FakeChecker(id: "A", isParallelSafe: false),
            FakeChecker(id: "B", status: .failed, isParallelSafe: false),
            FakeChecker(id: "C", isParallelSafe: false),
            FakeChecker(id: "D"),
        ]
        let outcome = await CheckerRunner(maxConcurrency: 4).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: false
        )
        #expect(outcome.results.map(\.checkerId) == ["A", "B"])
        #expect(outcome.truncation?.stoppedAt == "B")
        #expect(outcome.truncation?.unreached == ["C", "D"])
    }

    @Test("A complete run carries no truncation, even with failures under continueOnFailure")
    func completeRunHasNoTruncation() async {
        let checkers: [any QualityChecker] = [
            FakeChecker(id: "A", status: .failed),
            FakeChecker(id: "B"),
        ]
        let outcome = await CheckerRunner(maxConcurrency: 4).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true
        )
        #expect(outcome.results.count == 2)
        #expect(outcome.truncation == nil)
    }

    @Test("Strict mode stops on a warning and records the truncation identically")
    func strictWarningTruncates() async {
        let checkers: [any QualityChecker] = [
            FakeChecker(id: "A", status: .warning, isParallelSafe: false),
            FakeChecker(id: "B", isParallelSafe: false),
        ]
        let outcome = await CheckerRunner(maxConcurrency: 4).run(
            checkers: checkers,
            configuration: Configuration(),
            strict: true,
            continueOnFailure: false
        )
        #expect(outcome.truncation?.stoppedAt == "A")
        #expect(outcome.truncation?.unreached == ["B"])
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
        ).results
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
        ).results
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
        ).results
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
        ).results
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
        ).results
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
        ).results
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
        ).results
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

    // MARK: - Failures are not cached
    //
    // A pass is a claim about the source, and this project already enforces the
    // invariants that make it safe to replay one: TemporalDeterminismAuditor forbids
    // wall-clock nondeterminism, StochasticDeterminismAuditor forbids unseeded
    // randomness. None of that reasoning holds for a failure. A failure can come from
    // contention, a killed subprocess, an OOM or a codesign hiccup — none of which are
    // functions of the source. Caching one asserts source-determinism for an outcome
    // that may not be source-determined.
    //
    // It also wedges the one workflow that re-presents an identical tree on purpose:
    // retrying a blocked commit. Any real edit rotates the fingerprint and forces a
    // genuine re-run, so a poisoned entry is invisible during ordinary development and
    // bites precisely when someone is trying to get unstuck — and is least inclined to
    // doubt a red result.

    @Test("A failed result is not cached — the checker re-runs")
    func failureIsNotCached() async throws {
        let dir = try tempDir()
        let input = dir.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        let cache = ResultCache(directory: dir.appendingPathComponent("cache"))
        let counter = CallCounter()
        let checker = FakeChecker(
            id: "failing", status: .failed, cacheInputFiles: [input.path], callCounter: counter
        )

        _ = await run(checker, cache: cache, useCache: true)
        _ = await run(checker, cache: cache, useCache: true)

        let count = await counter.count
        #expect(count == 2, "An unchanged tree must not replay a failure — that is the commit-retry deadlock")
    }

    @Test("A failure replayed once does not persist after the cause clears")
    func failureDoesNotOutliveItsCause() async throws {
        let dir = try tempDir()
        let input = dir.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        let cache = ResultCache(directory: dir.appendingPathComponent("cache"))

        // A transient failure — contention, a killed subprocess — then the same tree
        // checked again by a checker that now succeeds. The second verdict must win.
        let failing = FakeChecker(id: "flaky", status: .failed, cacheInputFiles: [input.path])
        _ = await run(failing, cache: cache, useCache: true)

        let passing = FakeChecker(id: "flaky", status: .passed, cacheInputFiles: [input.path])
        let results = await run(passing, cache: cache, useCache: true)

        #expect(results.first?.status == .passed, "The stale failure must not outlive the condition that caused it")
    }

    @Test("A failure already on disk does not replay, and is evicted")
    func preExistingFailureDoesNotReplay() async throws {
        // Distinct from "a new failure is not written": guarding the store is
        // forward-only, and there were 166 such entries across 26 repos on this
        // machine when the bug was found. Those must self-heal on next run rather
        // than need manual deletion or a cache-version bump.
        let dir = try tempDir()
        let input = dir.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        let cacheDir = dir.appendingPathComponent("cache")
        let cache = ResultCache(directory: cacheDir)

        // Poison the cache directly, as a pre-fix gate run would have left it.
        let fingerprint = CheckerFingerprint.compute(
            checkerId: "poisoned",
            inputs: CacheInputs(files: [input.path]),
            gateHash: "gate-hash"
        )
        cache.store(
            CheckResult(checkerId: "poisoned", status: .failed, diagnostics: [], duration: .zero),
            checkerId: "poisoned",
            fingerprint: fingerprint
        )

        let counter = CallCounter()
        let checker = FakeChecker(
            id: "poisoned", status: .passed, cacheInputFiles: [input.path], callCounter: counter
        )
        let results = await run(checker, cache: cache, useCache: true)

        let count = await counter.count
        #expect(count == 1, "The poisoned entry must be a miss, not a replay")
        #expect(results.first?.status == .passed, "The real verdict must win over the stale one")
        // The key is not empty afterwards — the passing run stored its own result
        // under it. What matters is that nothing failed survives to be replayed.
        #expect(
            cache.load(checkerId: "poisoned", fingerprint: fingerprint)?.status != .failed,
            "A failed entry must not survive a read, or it poisons every later run too"
        )
    }

    @Test("A warning is still cached — the speed benefit is not sacrificed")
    func warningIsStillCached() async throws {
        let dir = try tempDir()
        let input = dir.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        let cache = ResultCache(directory: dir.appendingPathComponent("cache"))
        let counter = CallCounter()
        let checker = FakeChecker(
            id: "warner", status: .warning, cacheInputFiles: [input.path], callCounter: counter
        )

        _ = await run(checker, cache: cache, useCache: true)
        _ = await run(checker, cache: cache, useCache: true)

        let count = await counter.count
        #expect(count == 1, "Warnings are findings about the source and stay cacheable")
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

    @Test("A replayed result says it was replayed")
    func cacheHitIsLabelled() async throws {
        // A cached result carries the notes of the run that produced it. Several checkers
        // print run-scoped coverage — "19 files indexed", "56 articles · 161 fences" — and
        // on a hit those describe a run that did not happen. The finding is still valid;
        // the note is a statement about the current run and is not. Say which it is.
        let dir = try tempDir()
        let input = dir.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        let cache = ResultCache(directory: dir.appendingPathComponent("cache"))
        let checker = FakeChecker(id: "cacheable", cacheInputFiles: [input.path])

        let fresh = await run(checker, cache: cache, useCache: true)
        let replayed = await run(checker, cache: cache, useCache: true)

        #expect(!fresh[0].diagnostics.contains { $0.ruleId == "cache.replayed" })
        #expect(replayed[0].diagnostics.contains { $0.ruleId == "cache.replayed" })
    }

    @Test("Replaying does not change the verdict or the findings")
    func replayPreservesTheResult() async throws {
        let dir = try tempDir()
        let input = dir.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        let cache = ResultCache(directory: dir.appendingPathComponent("cache"))
        let checker = FakeChecker(id: "cacheable", cacheInputFiles: [input.path])

        let fresh = await run(checker, cache: cache, useCache: true)
        let replayed = await run(checker, cache: cache, useCache: true)

        #expect(fresh[0].status == replayed[0].status)
        // The marker is additive: every original diagnostic survives.
        let original = fresh[0].diagnostics.count
        let carried = replayed[0].diagnostics.filter { $0.ruleId != "cache.replayed" }.count
        #expect(carried == original)
    }

}
