import Foundation

/// Runs quality checkers concurrently with bounded parallelism, preserving order.
///
/// The gate historically ran checkers sequentially, so wall-time was the sum of every
/// checker. Because ``QualityChecker`` is `Sendable`, checkers only read shared state
/// (index-dependent checkers *locate* an existing index store and never build it), and
/// the run loop performs no writes, the checkers can run concurrently. This collapses
/// wall-time to roughly the slowest single checker without changing any check.
public struct CheckerRunner: Sendable {

    /// Maximum number of checkers allowed to run at once.
    public let maxConcurrency: Int

    /// Creates a runner.
    ///
    /// - Parameter maxConcurrency: The most checkers to run concurrently. Defaults to the
    ///   machine's active processor count. Clamped to at least 1.
    public init(maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Runs `checkers` and returns their results in the same order as `checkers`.
    ///
    /// Checkers are partitioned by ``QualityChecker/isParallelSafe``. Non-parallel-safe
    /// checkers (those that spawn `swift build`/`swift test` and lock the SwiftPM `.build`
    /// directory, or mutate the build tree) run **sequentially** in checker order, before
    /// the parallel-safe checkers run concurrently in a bounded task group. This preserves
    /// correctness — the `.build` lock is never contended and no checker's index store is
    /// deleted out from under a concurrent reader — while still collapsing wall-time of the
    /// many pure AST/file checkers to roughly the slowest one.
    ///
    /// A checker that throws is converted to a failed ``CheckResult`` tagged with rule
    /// `checker-error`, matching the previous sequential behavior. Every result — including
    /// synthesized error results — is passed through `transform` (used to apply overrides)
    /// before its pass/fail status is judged.
    ///
    /// When `continueOnFailure` is `false`, the runner stops after the first failing
    /// (post-`transform`) result: a failing sequential checker skips the parallel phase, and
    /// a failing parallel checker cancels the remaining group. Results are always returned in
    /// checker order.
    ///
    /// - Parameters:
    ///   - checkers: The checkers to run.
    ///   - configuration: The gate configuration passed to each checker.
    ///   - strict: When `true`, a `.warning` result counts as failing for early-exit.
    ///   - continueOnFailure: When `false`, stop after the first failing result.
    ///   - transform: Applied to each result before judging pass/fail (e.g. override application).
    ///   - onError: Invoked with the checker id and error when a checker throws (for logging).
    /// - Returns: The results in checker order.
    public func run(
        checkers: [any QualityChecker],
        configuration: Configuration,
        strict: Bool,
        continueOnFailure: Bool,
        transform: @Sendable @escaping (CheckResult) -> CheckResult = { $0 },
        onError: @Sendable @escaping (String, any Error) -> Void = { _, _ in }
    ) async -> [CheckResult] {
        if checkers.isEmpty { return [] }

        @Sendable func evaluate(_ checker: any QualityChecker) async -> CheckResult {
            do {
                let raw = try await checker.check(configuration: configuration)
                return transform(raw)
            } catch {
                onError(checker.id, error)
                let synthesized = CheckResult(
                    checkerId: checker.id,
                    status: .failed,
                    diagnostics: [
                        Diagnostic(
                            severity: .error,
                            message: "Checker failed: \(error.localizedDescription)",
                            ruleId: "checker-error"
                        )
                    ],
                    duration: .zero
                )
                return transform(synthesized)
            }
        }

        func isFailing(_ result: CheckResult) -> Bool {
            result.status == .failed || (strict && result.status == .warning)
        }

        // Preserve each checker's original position so results report in checker order,
        // regardless of which partition or completion order they came from.
        let indexed = Array(checkers.enumerated())
        let sequentialCheckers = indexed.filter { !$0.element.isParallelSafe }
        let parallelCheckers = indexed.filter { $0.element.isParallelSafe }

        var collected: [(Int, CheckResult)] = []
        collected.reserveCapacity(checkers.count)

        // Phase 1: exclusive checkers, strictly sequential (never overlapping `.build`).
        var stoppedEarly = false
        for (index, checker) in sequentialCheckers {
            let result = await evaluate(checker)
            collected.append((index, result))
            if !continueOnFailure && isFailing(result) {
                stoppedEarly = true
                break
            }
        }

        // Phase 2: parallel-safe checkers, concurrent and bounded.
        if !stoppedEarly && !parallelCheckers.isEmpty {
            let parallelResults = await runConcurrently(
                parallelCheckers,
                continueOnFailure: continueOnFailure,
                evaluate: evaluate,
                isFailing: isFailing
            )
            collected.append(contentsOf: parallelResults)
        }

        return collected.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Runs the given indexed checkers concurrently, bounded by ``maxConcurrency``.
    private func runConcurrently(
        _ work: [(offset: Int, element: any QualityChecker)],
        continueOnFailure: Bool,
        evaluate: @escaping @Sendable (any QualityChecker) async -> CheckResult,
        isFailing: @escaping (CheckResult) -> Bool
    ) async -> [(Int, CheckResult)] {
        let limit = min(maxConcurrency, work.count)
        return await withTaskGroup(of: (Int, CheckResult).self) { group in
            var nextSlot = 0
            while nextSlot < limit {
                let (index, checker) = (work[nextSlot].offset, work[nextSlot].element)
                group.addTask { (index, await evaluate(checker)) }
                nextSlot += 1
            }

            var results: [(Int, CheckResult)] = []
            results.reserveCapacity(work.count)

            while let (index, result) = await group.next() {
                results.append((index, result))

                if !continueOnFailure && isFailing(result) {
                    group.cancelAll()
                    break
                }

                if nextSlot < work.count {
                    let (nextIndex, checker) = (work[nextSlot].offset, work[nextSlot].element)
                    group.addTask { (nextIndex, await evaluate(checker)) }
                    nextSlot += 1
                }
            }

            return results
        }
    }
}
