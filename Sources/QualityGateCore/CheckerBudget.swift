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
        floor: TimeInterval = 900,
        headroom: Double = 3,
        firstRun: TimeInterval = 3_600
    ) -> TimeInterval {
        guard let lastSuccess, lastSuccess > 0 else { return firstRun }
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
        // silent: an absent or unreadable record is the normal first-run state, and the
        // fallback is a deliberately generous budget rather than a failure.
        guard let text = try? String(contentsOf: record(named: name, root: root), encoding: .utf8),
              let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return seconds
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
