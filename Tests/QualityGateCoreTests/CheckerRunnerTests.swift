import Foundation
import Testing
@testable import QualityGateCore

// MARK: - Test doubles

/// A deterministic fake checker for exercising the runner.
private struct FakeChecker: QualityChecker {
    let id: String
    let name: String
    let status: CheckResult.Status
    let delay: Duration
    /// Optional tracker to record concurrent execution.
    let tracker: ConcurrencyTracker?
    /// If true, throws instead of returning a result.
    let throwsError: Bool
    let isParallelSafe: Bool

    init(
        id: String,
        status: CheckResult.Status = .passed,
        delay: Duration = .zero,
        tracker: ConcurrencyTracker? = nil,
        throwsError: Bool = false,
        isParallelSafe: Bool = true
    ) {
        self.id = id
        self.name = id
        self.status = status
        self.delay = delay
        self.tracker = tracker
        self.throwsError = throwsError
        self.isParallelSafe = isParallelSafe
    }

    struct Boom: Error {}

    func check(configuration: Configuration) async throws -> CheckResult {
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
