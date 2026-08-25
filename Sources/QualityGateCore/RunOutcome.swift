import Foundation

/// How a run that stopped early stopped.
///
/// A default run halts at its first failing checker, and every checker ordered after
/// it never executes. Collapsing that into "not selected" makes an early stop read
/// as a deliberately narrowed run — an absence of findings where the truth is an
/// absence of information. This record keeps the two distinguishable all the way to
/// the summary line and the telemetry artifact.
public struct RunTruncation: Sendable, Equatable {
    /// The failing checker the run stopped at.
    public let stoppedAt: String
    /// Checker ids selected for this run that never executed because of the stop.
    public let unreached: [String]

    /// Creates a truncation record.
    /// - Parameters:
    ///   - stoppedAt: The failing checker the run stopped at.
    ///   - unreached: Selected checkers that never executed.
    public init(stoppedAt: String, unreached: [String]) {
        self.stoppedAt = stoppedAt
        self.unreached = unreached
    }
}

/// What a ``CheckerRunner`` run produced, and whether it produced all of it.
///
/// The results alone cannot say whether the run completed: a run of 8 results from
/// 45 selected checkers is either a narrow selection or a truncated default run,
/// and the two mean opposite things about the 37 missing verdicts.
public struct RunOutcome: Sendable {
    /// The results of every checker that ran, in checker order.
    public let results: [CheckResult]
    /// How the run stopped early, or `nil` when every selected checker ran.
    public let truncation: RunTruncation?

    /// Creates a run outcome.
    /// - Parameters:
    ///   - results: The results of every checker that ran, in checker order.
    ///   - truncation: How the run stopped early; `nil` for a complete run.
    public init(results: [CheckResult], truncation: RunTruncation?) {
        self.results = results
        self.truncation = truncation
    }
}
