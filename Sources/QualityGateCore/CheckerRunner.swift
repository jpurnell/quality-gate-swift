import Foundation
#if canImport(os)
import os
#endif

/// Runs quality checkers concurrently with bounded parallelism, preserving order.
///
/// The gate historically ran checkers sequentially, so wall-time was the sum of every
/// checker. Because ``QualityChecker`` is `Sendable`, checkers only read shared state
/// (index-dependent checkers *locate* an existing index store and never build it), and
/// the run loop performs no writes, the checkers can run concurrently. This collapses
/// wall-time to roughly the slowest single checker without changing any check.
public struct CheckerRunner: Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "CheckerRunner")

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
    /// An early stop is reported, not implied: the returned ``RunOutcome`` carries a
    /// ``RunTruncation`` naming the stopping checker and every selected checker that never
    /// ran because of it. Truncation and selection are different facts — a checker missing
    /// from a truncated run contributed no evidence, and reporting must not let its absence
    /// read as a clean result.
    ///
    /// - Parameters:
    ///   - checkers: The checkers to run.
    ///   - configuration: The gate configuration passed to each checker.
    ///   - strict: When `true`, a `.warning` result counts as failing for early-exit.
    ///   - continueOnFailure: When `false`, stop after the first failing result.
    ///   - cache: Optional result cache consulted when `useCache` is `true`; `nil` disables caching.
    ///   - gateHash: Identity hash of the gate build, mixed into each cache fingerprint so a gate rebuild invalidates stale entries.
    ///   - useCache: When `true` and `cache` is non-`nil`, reuse cached results for unchanged checker inputs.
    ///   - digests: Per-run file-digest memo shared across every fingerprint this run computes.
    ///     Callers with post-run fingerprinting of their own (telemetry sidecars) pass theirs in
    ///     so the whole process hashes each input file once.
    ///   - includeNonHermetic: When `true`, skip the hermeticity clamp so `.temporal`
    ///     and `.external` checkers can fail the gate (for jobs that *want* to block on
    ///     staleness or upstream drift). Off by default.
    ///   - transform: Applied to each result before judging pass/fail (e.g. override application).
    ///   - onError: Invoked with the checker id and error when a checker throws (for logging).
    /// - Returns: The results in checker order, plus the truncation record when the run
    ///   stopped early.
    public func run(
        checkers: [any QualityChecker],
        configuration: Configuration,
        strict: Bool,
        continueOnFailure: Bool,
        cache: ResultCache? = nil,
        gateHash: String = "",
        useCache: Bool = false,
        digests: FileDigestCache = FileDigestCache(),
        includeNonHermetic: Bool = false,
        transform: @Sendable @escaping (CheckResult) -> CheckResult = { $0 },
        onError: @Sendable @escaping (String, any Error) -> Void = { _, _ in }
    ) async -> RunOutcome {
        if checkers.isEmpty { return RunOutcome(results: [], truncation: nil) }

        // Runs the checker, converting a throw into a failed `checker-error` result —
        // except for `.external` checkers, where a throw means the out-of-tree state was
        // unreachable. That is not evidence against the commit, so it resolves to
        // `.skipped` carrying the reason rather than to a failure.
        @Sendable func runAndSynthesize(_ checker: any QualityChecker) async -> CheckResult {
            do {
                return try await checker.check(configuration: configuration)
            } catch {
                Self.logger.error("Checker '\(checker.id, privacy: .public)' threw: \(error.localizedDescription, privacy: .public)")
                onError(checker.id, error)

                if checker.hermeticity == .external && !includeNonHermetic {
                    return HermeticityClamp.unavailable(
                        checkerId: checker.id, reason: error.localizedDescription)
                }

                return CheckResult(
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
            }
        }

        // Evaluates a checker, consulting the result cache when it is enabled AND the checker
        // opted in via `cacheInputs`. The cache stores the RAW checker output; `transform`
        // (override application) is applied per-run to both cache hits and misses, so overrides
        // never get baked into a cached result.
        // Applies the hermeticity clamp *after* `transform`, so override matching still
        // sees each diagnostic's original severity. The clamp is a pure function of the
        // declared class, so it is equally correct on a cache hit and a fresh run.
        @Sendable func clamped(_ result: CheckResult, _ checker: any QualityChecker) -> CheckResult {
            guard !includeNonHermetic else { return result }
            return HermeticityClamp.apply(to: result, hermeticity: checker.hermeticity)
        }

        /// Labels a result served from cache, so its notes are not read as describing
        /// this run.
        ///
        /// A cached result carries the diagnostics of the run that produced it, and several
        /// checkers print run-scoped coverage — "648 files indexed", "56 articles · 161
        /// fences", "35 target(s) owning a DocC catalogue". Those are the figures this
        /// project prefers precisely because a run computes them and nothing stores them;
        /// replaying one silently turns it back into a stored number, describing a run that
        /// did not happen. The findings remain valid — they were computed from the same
        /// inputs — so the marker is additive and changes no verdict.
        @Sendable func markReplayed(_ result: CheckResult) -> CheckResult {
            var diagnostics = result.diagnostics
            diagnostics.append(Diagnostic(
                severity: .note,
                message: "Replayed from cache: this checker did not run. Any coverage or timing figures above describe the run that produced this result, not this one. Re-run with --no-cache to recompute them.",
                ruleId: "cache.replayed"
            ))
            return CheckResult(
                checkerId: result.checkerId,
                status: result.status,
                diagnostics: diagnostics,
                duration: result.duration
            )
        }

        @Sendable func evaluate(_ checker: any QualityChecker) async -> CheckResult {
            if useCache, let cache, let inputs = checker.cacheInputs(configuration: configuration) {
                let fingerprint = CheckerFingerprint.compute(
                    checkerId: checker.id, inputs: inputs, gateHash: gateHash, digests: digests
                )
                // A failure is never replayed, and is evicted on sight.
                //
                // A pass is a claim about the source, and this project enforces the
                // invariants that make replaying one safe: `TemporalDeterminismAuditor`
                // forbids wall-clock nondeterminism, `StochasticDeterminismAuditor`
                // forbids unseeded randomness. None of that reasoning covers a failure,
                // which can come from contention, a killed subprocess, an OOM or a
                // codesign hiccup — none of them functions of the source. Caching one
                // asserts source-determinism for an outcome that may not have it.
                //
                // Evicting on read rather than only guarding the write matters: a
                // store-side guard is forward-only and leaves every entry already on
                // disk replayable forever. It also fixes the workflow this actually
                // wedges — retrying a blocked commit is the one thing that re-presents
                // an identical tree on purpose, so a poisoned entry stays invisible
                // during ordinary editing and bites when someone is trying to get
                // unstuck, and is least inclined to doubt a red result.
                if let cached = cache.load(checkerId: checker.id, fingerprint: fingerprint) {
                    if cached.status.isPassing {
                        return clamped(transform(markReplayed(cached)), checker)
                    }
                    cache.remove(checkerId: checker.id, fingerprint: fingerprint)
                }
                let fresh = await runAndSynthesize(checker)
                if fresh.status.isPassing {
                    cache.store(fresh, checkerId: checker.id, fingerprint: fingerprint)
                }
                return clamped(transform(fresh), checker)
            }
            return clamped(transform(await runAndSynthesize(checker)), checker)
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
        var stoppedAt: String?
        for (index, checker) in sequentialCheckers {
            let result = await evaluate(checker)
            collected.append((index, result))
            if !continueOnFailure && isFailing(result) {
                stoppedAt = checker.id
                break
            }
        }

        // Phase 2: parallel-safe checkers, concurrent and bounded.
        if stoppedAt == nil && !parallelCheckers.isEmpty {
            let (parallelResults, parallelStop) = await runConcurrently(
                parallelCheckers,
                continueOnFailure: continueOnFailure,
                evaluate: evaluate,
                isFailing: isFailing
            )
            collected.append(contentsOf: parallelResults)
            stoppedAt = parallelStop
        }

        let results = collected.sorted { $0.0 < $1.0 }.map(\.1)

        // Truncation is computed from what actually ran, not from the break that was
        // taken: a checker started in the parallel group and then cancelled produced no
        // result, and it belongs in `unreached` exactly as much as one never started.
        var truncation: RunTruncation?
        if let stoppedAt {
            let reached = Set(collected.map(\.0))
            let unreached = indexed
                .filter { !reached.contains($0.offset) }
                .map(\.element.id)
            if !unreached.isEmpty {
                truncation = RunTruncation(stoppedAt: stoppedAt, unreached: unreached)
            }
        }
        return RunOutcome(results: results, truncation: truncation)
    }

    /// Runs the given indexed checkers concurrently, bounded by ``maxConcurrency``.
    ///
    /// Returns the collected results plus the id of the failing checker that stopped the
    /// group, or `nil` when the group ran to completion.
    private func runConcurrently(
        _ work: [(offset: Int, element: any QualityChecker)],
        continueOnFailure: Bool,
        evaluate: @escaping @Sendable (any QualityChecker) async -> CheckResult,
        isFailing: @escaping (CheckResult) -> Bool
    ) async -> ([(Int, CheckResult)], stoppedAt: String?) {
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
            var stoppedAt: String?

            while let (index, result) = await group.next() {
                results.append((index, result))

                if !continueOnFailure && isFailing(result) {
                    stoppedAt = result.checkerId
                    group.cancelAll()
                    break
                }

                if nextSlot < work.count {
                    let (nextIndex, checker) = (work[nextSlot].offset, work[nextSlot].element)
                    group.addTask { (nextIndex, await evaluate(checker)) }
                    nextSlot += 1
                }
            }

            return (results, stoppedAt)
        }
    }
}
