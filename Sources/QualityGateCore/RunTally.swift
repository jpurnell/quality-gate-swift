import Foundation

/// The counts and the verdict of a run, computed in one place.
///
/// `--strict` says *"Treat warnings as failures"*. For that to be literally true, the
/// number printed after "warning(s)" and the number `--strict` gates on have to be the
/// same number. They were not: the summary counted warning diagnostics, the exit code read
/// checker statuses, and there were four hand-written copies of "does this fail under
/// strict" — none of which read the count the user sees.
///
/// Here ``warnings`` is a stored property. The reporters print it and ``verdict(strict:truncated:)``
/// gates on it, so the two agree by construction rather than by several copies agreeing.
public struct RunTally: Sendable, Equatable {

    /// Error-severity diagnostics across the run.
    public let errors: Int
    /// Warning-severity diagnostics across the run — the printed number, and the number
    /// `--strict` gates on.
    public let warnings: Int
    /// Ids of the checkers whose reconciled status is `.failed`, in run order.
    public let failedCheckers: [String]
    /// Ids of the checkers whose reconciled status is `.warning`, in run order.
    public let warnedCheckers: [String]
    /// Ids of the checkers whose reconciled status is `.passed`, in run order.
    public let passedCheckers: [String]
    /// Ids of the checkers that were skipped, in run order.
    public let skippedCheckers: [String]

    /// Whether a warning carried by a **skipped** result is counted, and so gates under
    /// `--strict`.
    ///
    /// The one decision point for that question; ``countsWarnings(of:)`` is its only
    /// reader. It is `true` because such warnings exist to say the skip is not a pass:
    /// `doc-code` and `doc-comment-code` skip with a `*.module-unavailable` warning —
    /// "no fence was examined" — when the module they compile against has not been built.
    /// The terminal prints that line under a warning glyph, so counting it keeps the
    /// printed number and the gated number the same number.
    ///
    /// The consequence: `quality-gate --strict --check doc-code` on a cold `.build` fails,
    /// where it used to exit 0 having examined nothing. The checker's status stays
    /// `.skipped` and the runner's early stop, which reads status, does not stop at it.
    ///
    /// Setting this to `false` excludes skipped results from ``warnings`` everywhere at
    /// once — the count line and the verdict move together — at the price of a printed
    /// warning the summary does not count.
    static let countsWarningsOnSkippedResults = true

    /// Whether `result`'s warning diagnostics belong in ``warnings``.
    ///
    /// - Parameter result: A reconciled result.
    /// - Returns: `true` unless the result is skipped and
    ///   ``countsWarningsOnSkippedResults`` is off.
    static func countsWarnings(of result: CheckResult) -> Bool {
        result.status != .skipped || countsWarningsOnSkippedResults
    }

    /// Tallies a run.
    ///
    /// The results are reconciled here as well as in the runner, so a caller cannot hand
    /// the tally a status its diagnostics contradict. Reconciliation is idempotent, so
    /// results that arrive already reconciled are unaffected.
    ///
    /// - Parameter results: The results of every checker that ran.
    public init(_ results: [CheckResult]) {
        let reconciled = results.map { $0.reconciled() }
        errors = reconciled.reduce(0) { $0 + $1.errorCount }
        warnings = reconciled
            .filter(Self.countsWarnings(of:))
            .reduce(0) { $0 + $1.warningCount }
        failedCheckers = reconciled.filter { $0.status == .failed }.map(\.checkerId)
        warnedCheckers = reconciled.filter { $0.status == .warning }.map(\.checkerId)
        passedCheckers = reconciled.filter { $0.status == .passed }.map(\.checkerId)
        skippedCheckers = reconciled.filter { $0.status == .skipped }.map(\.checkerId)
    }

    /// What a run amounts to.
    public enum Verdict: Sendable, Equatable {
        /// Every selected checker ran and nothing failed.
        case passed
        /// At least one checker failed.
        case failed
        /// No checker failed, but the run is under `--strict` and counted a warning.
        case failedByStrictWarnings
        /// Nothing failed, but the run stopped before every selected checker ran — the
        /// question was not answered.
        case incomplete
    }

    /// The run's verdict.
    ///
    /// In order: any failed checker is `.failed`; under `strict`, a non-zero ``warnings``
    /// is `.failedByStrictWarnings`; a truncated run in which nothing failed is
    /// `.incomplete`; otherwise `.passed`.
    ///
    /// Truncation is asked about after the two failures, not before. Under `--strict` the
    /// runner stops *at* a warning, so a run stopped that way is truncated and has also
    /// failed — and `.incomplete` is the verdict for "nothing failed, but not everything
    /// ran", which is not that run.
    ///
    /// - Parameters:
    ///   - strict: Whether warnings fail the run, as under `--strict`.
    ///   - truncated: Whether the run stopped before every selected checker ran.
    /// - Returns: The verdict. Anything but `.passed` is a non-zero exit.
    public func verdict(strict: Bool, truncated: Bool) -> Verdict {
        if !failedCheckers.isEmpty { return .failed }
        if strict && warnings > 0 { return .failedByStrictWarnings }
        if truncated { return .incomplete }
        return .passed
    }
}
