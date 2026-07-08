import Foundation

/// The pass/fail outcome of a single test in one run.
public struct TestOutcome: Sendable, Equatable, Codable {
    /// Enclosing suite/class name (best-effort; empty when the output does not name one).
    public let suite: String
    /// Test display name.
    public let test: String
    /// Whether the test passed.
    public let passed: Bool

    /// Creates a test outcome.
    public init(suite: String, test: String, passed: Bool) {
        self.suite = suite
        self.test = test
        self.passed = passed
    }

    /// Suite-scoped identity used to match a test across runs.
    public var key: String { "\(suite)\u{001F}\(test)" }
}

/// A recorded test run: the full roster plus the inputs that gate a flip.
///
/// A flip is only meaningful when the code under test is unchanged, so the record
/// carries the package fingerprint (a digest of the sources + manifest) alongside a
/// `loadProxy` (concurrent worker/gate count) that hints at scheduler pressure.
public struct TestRunRecord: Sendable, Equatable, Codable {
    /// Digest of the package's sources + manifest at run time.
    public let packageFingerprint: String
    /// Short commit hash at run time (best-effort; empty when unavailable).
    public let commit: String
    /// Load proxy — concurrent worker / gate count when the run executed.
    public let loadProxy: Int
    /// Every test's outcome in this run.
    public let outcomes: [TestOutcome]

    /// Creates a test run record.
    public init(packageFingerprint: String, commit: String, loadProxy: Int, outcomes: [TestOutcome]) {
        self.packageFingerprint = packageFingerprint
        self.commit = commit
        self.loadProxy = loadProxy
        self.outcomes = outcomes
    }
}

/// A test whose outcome changed between two runs of the *same* package fingerprint —
/// i.e. scheduler-dependent behavior, not a code change.
public struct TestOutcomeFlip: Sendable, Equatable {
    /// Enclosing suite/class name.
    public let suite: String
    /// Test display name.
    public let test: String
    /// Whether the test passed in the previous run.
    public let previouslyPassed: Bool
    /// Whether the test passed in the current run.
    public let nowPassed: Bool
    /// Commit of the previous run.
    public let previousCommit: String
    /// Commit of the current run.
    public let currentCommit: String
}

/// Detects tests whose outcome flipped between two runs with an identical package
/// fingerprint. Such a flip is scheduler-dependent behavior — the very class of race
/// the 2-consecutive-clean-runs flake policy cannot catch.
public enum FlipDetector {
    /// Returns the flips between `previous` and `current`.
    ///
    /// Returns empty when there is no prior record, or when the package fingerprint
    /// changed (an outcome change is then expected, not a flip). Only tests present in
    /// both runs with differing `passed` values are reported.
    public static func flips(previous: TestRunRecord?, current: TestRunRecord) -> [TestOutcomeFlip] {
        guard let previous else { return [] }
        // A changed package legitimately changes outcomes — not a flip.
        guard previous.packageFingerprint == current.packageFingerprint else { return [] }

        var previousByKey: [String: TestOutcome] = [:]
        for outcome in previous.outcomes {
            previousByKey[outcome.key] = outcome
        }

        var flips: [TestOutcomeFlip] = []
        for outcome in current.outcomes {
            guard let prior = previousByKey[outcome.key], prior.passed != outcome.passed else { continue }
            flips.append(TestOutcomeFlip(
                suite: outcome.suite,
                test: outcome.test,
                previouslyPassed: prior.passed,
                nowPassed: outcome.passed,
                previousCommit: previous.commit,
                currentCommit: current.commit
            ))
        }
        return flips
    }
}
