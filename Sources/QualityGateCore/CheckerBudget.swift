import Foundation
import QualityGateLogging

/// How long a checker's subprocess is allowed to take, derived from how long it last took.
///
/// `ProcessRunner.run` defaults to `timeout: 600`. That suits the short commands most of its
/// callers issue — `git rev-parse`, `xcrun --find` — and it is inherited by callers that do
/// nothing of the kind: `test` runs a whole suite, `doc-lint` builds DocC for every target
/// owning a catalogue, `unreachable` builds an index store. None of them chose 600; they got
/// it, and it fit until the work grew past it.
///
/// The failure that produces is quiet. A checker killed at its ceiling has produced no finding,
/// so the run reports a tool that appears to hang rather than a budget that was too small — and
/// in one case on this repository a cut-off run was read as a *pass*, which is worse than
/// either. (`test-timeout` now names that case explicitly.)
///
/// A budget derived from the work's own history follows it instead of waiting to be outgrown,
/// which is the same preference for a computed number over a remembered one that `doc-lint`'s
/// coverage note exists to serve.
public enum CheckerBudget {

    /// The budget for `work`, in seconds.
    ///
    /// - Parameters:
    ///   - lastSuccess: Duration of the last successful run, or `nil` when none is recorded.
    ///   - floor: The smallest budget ever issued, so ordinary variance cannot kill a fast run.
    ///   - headroom: Multiple of the observed duration, absorbing growth between runs.
    ///   - firstRun: Budget when nothing is recorded — a cold tree doing the work for the
    ///     first time, which is exactly when a too-small budget is most likely to fire.
    /// - Returns: The budget in seconds.
    public static func seconds(
        lastSuccess: TimeInterval?,
        floor: TimeInterval = CheckerBudget.floor,
        headroom: Double = 3,
        firstRun: TimeInterval = 3_600
    ) -> TimeInterval {
        guard let lastSuccess, lastSuccess > 0, lastSuccess.isFinite else { return firstRun }
        return max(floor, lastSuccess * headroom)
    }

    /// Where a named piece of work keeps its observed duration: beside the build it describes,
    /// so `clean` discards the figure along with the thing it is a statement about.
    static func record(named name: String, root: String) -> URL {
        URL(fileURLWithPath: root)
            .appendingPathComponent(".build/quality-gate-duration-\(name)", isDirectory: false)
    }

    /// The last successful duration for `name`, or `nil` when there is no usable record.
    public static func lastSuccess(named name: String, root: String) -> TimeInterval? {
        // An absent or unreadable record is the normal first-run state, and the fallback is a
        // deliberately generous budget rather than a failure.
        // silent: no record yet is the first-run state; the caller falls back to a generous budget
        guard let text = try? String(contentsOf: record(named: name, root: root), encoding: .utf8),
              let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              // `TimeInterval("inf")` and `TimeInterval("nan")` both parse. An infinite record
              // times the headroom is an infinite budget, which the process kernel refuses —
              // and before 1.1.0 obeyed, as no deadline at all. A record that is not a
              // duration is no record.
              seconds.isFinite
        else { return nil }
        return seconds
    }

    // MARK: - An allowance, and where it came from

    /// A budget together with the reason it is that figure.
    ///
    /// A timeout message that says only "900s" leaves the reader guessing whether that was
    /// chosen, derived or defaulted — and so whether the remedy is a config key, a rerun, or
    /// nothing. The source travels with the number so the message can say.
    public struct Allowance: Sendable, Equatable {

        /// Where a budget's figure came from.
        public enum Source: Sendable, Equatable {
            /// Set in `.quality-gate.yml` under `budgets:`.
            case configured
            /// Derived from the last successful run, which took this many seconds.
            case lastSuccess(TimeInterval)
            /// No successful run is recorded, so the generous first-run figure applies.
            case firstRun
            /// The process runner's own default, for a tool that keeps no history.
            case runnerDefault
            /// Read back from the process runner's note in a transcript, when the run itself
            /// was not recorded.
            case reportedByRunner
        }

        /// The checker the budget belongs to.
        public let checkerId: String
        /// The budget, in seconds.
        public let seconds: TimeInterval
        /// Where the figure came from.
        public let source: Source

        /// Creates an allowance.
        public init(checkerId: String, seconds: TimeInterval, source: Source) {
            self.checkerId = checkerId
            self.seconds = seconds
            self.source = source
        }

        /// Why the budget is the figure it is, as a timeout message states it.
        public var explanation: String {
            switch source {
            case .configured:
                return "set by `budgets.\(checkerId)` in .quality-gate.yml"
            case .lastSuccess(let last):
                return "three times the last successful run (\(ToolRun.seconds(last))), "
                    + "and never less than \(ToolRun.seconds(CheckerBudget.floor))"
            case .firstRun:
                return "the first-run budget, because no successful run is recorded yet"
            case .runnerDefault:
                return "the process runner's default; no `budgets.\(checkerId)` is set"
            case .reportedByRunner:
                return "as the process runner reported it"
            }
        }
    }

    /// The smallest derived budget: ordinary variance must not kill a fast run.
    public static let floor: TimeInterval = 900

    /// The process runner's default timeout, which a tool with no history runs under.
    public static let runnerDefault: TimeInterval = 600

    /// The allowance for `checkerId`: the configured figure if there is one, otherwise the
    /// one derived from the last successful run.
    ///
    /// A configured budget is used as written. It is not raised to the floor and not scaled
    /// by the load: the person who wrote it chose it, and a budget that silently becomes a
    /// different number under contention is its own way of failing without saying so.
    ///
    /// - Parameters:
    ///   - checkerId: The checker asking.
    ///   - configured: The figure under `budgets.<checkerId>`, if any.
    ///   - lastSuccess: Duration of the last successful run, or `nil` when none is recorded.
    /// - Returns: The allowance and its source.
    public static func allowance(
        for checkerId: String,
        configured: TimeInterval?,
        lastSuccess: TimeInterval?
    ) -> Allowance {
        if let configured {
            return Allowance(checkerId: checkerId, seconds: configured, source: .configured)
        }
        guard let lastSuccess, lastSuccess > 0, lastSuccess.isFinite else {
            return Allowance(
                checkerId: checkerId, seconds: seconds(lastSuccess: nil), source: .firstRun)
        }
        return Allowance(
            checkerId: checkerId,
            seconds: seconds(lastSuccess: lastSuccess),
            source: .lastSuccess(lastSuccess))
    }

    /// The allowance for `checkerId` in the package at `root`, reading its recorded duration.
    ///
    /// - Parameters:
    ///   - checkerId: The checker asking; also the name its duration is recorded under.
    ///   - root: The package root.
    ///   - configuration: The run's configuration, for `budgets:`.
    /// - Returns: The allowance and its source.
    public static func allowance(
        for checkerId: String, root: String, configuration: Configuration
    ) -> Allowance {
        allowance(
            for: checkerId,
            configured: configuration.budgets.seconds(for: checkerId),
            lastSuccess: lastSuccess(named: checkerId, root: root))
    }

    /// The allowance for a tool that keeps no history: the configured figure, or the process
    /// runner's default.
    ///
    /// - Parameters:
    ///   - checkerId: The checker asking.
    ///   - configuration: The run's configuration, for `budgets:`.
    /// - Returns: The allowance and its source.
    public static func fixedAllowance(
        for checkerId: String, configuration: Configuration
    ) -> Allowance {
        if let configured = configuration.budgets.seconds(for: checkerId) {
            return Allowance(checkerId: checkerId, seconds: configured, source: .configured)
        }
        return Allowance(checkerId: checkerId, seconds: runnerDefault, source: .runnerDefault)
    }

    /// Records a successful duration for `name`, for the next run to size itself against.
    ///
    /// Only successes are recorded. A killed or failing run says nothing about how long the
    /// work takes when it succeeds, and feeding a timeout back in would ratchet the budget up
    /// on exactly the runs that should not extend it.
    public static func record(_ duration: TimeInterval, named name: String, root: String) {
        let url = record(named: name, root: root)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Interpolation, not `String(format:)` — which bridges to the C printf ABI — and
            // not `.formatted()`, which is locale-aware and would write "453,0" where the
            // decimal separator is a comma. `TimeInterval(_:)` cannot parse that, so the record
            // would silently never read back and every run would size itself as a first run.
            try "\(duration.rounded())".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // The next run falls back to the first-run budget, which is generous, so failing to
            // record costs a longer ceiling rather than a wrong answer.
            logger.debug("could not record the \(name, privacy: .public) duration; the next run will size itself as a first run: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let logger = Logger(subsystem: "com.quality-gate", category: "CheckerBudget")
}
