import Foundation

/// Time budgets, in seconds, for the checkers that launch a build tool.
///
/// ```yaml
/// budgets:
///   test: 1800
///   build: 1200
/// ```
///
/// Unset, `build`, `test` and `doc-lint` each derive a budget from how long their last
/// successful run took — three times that, never less than 900 seconds, and 3,600 seconds
/// when nothing is recorded — and `xcode-build` runs under the process runner's 600 seconds.
/// A figure set here replaces that for the named checker, exactly as written.
///
/// ## Why the budget does not follow the machine's load
///
/// It could: a load average of 200 on twelve cores is a good predictor that a four-minute
/// suite will take fifteen. It deliberately does not. A budget that stretches itself is a
/// number nobody chose and nobody can read off the configuration, and the failure it
/// replaces — a run cut off without saying so — would return as a run that takes an hour
/// without saying why. The derived budget already follows the work, which is the part that
/// can be measured in advance; the load is reported in the timeout message instead, so the
/// person reading it can decide between waiting and raising this key.
///
/// ## Why a wrong entry is refused
///
/// Every other field decodes with a default, so a misspelled checker id here would be
/// accepted and ignored — the run would time out at the old figure with the new one sitting
/// in the file. An id that names no budgeted checker, and a figure that is not a positive
/// finite number of seconds, both stop the run at startup.
public struct CheckerBudgetsConfig: Sendable, Equatable {

    /// The checkers a budget applies to: the ones whose work is a single long tool run.
    public static let budgetedCheckers = ["build", "doc-lint", "test", "xcode-build"]

    /// The largest budget accepted — the process kernel's own maximum, past which a deadline
    /// stops being one.
    public static let maximumSeconds: TimeInterval = ProcessRunner.maximumTimeout

    /// The configured budgets, by checker id.
    public let secondsByChecker: [String: TimeInterval]

    /// No budget configured: every checker derives its own.
    public static let `default` = CheckerBudgetsConfig(unchecked: [:])

    /// A `budgets:` entry the gate will not act on.
    public enum Invalid: Error, Equatable, LocalizedError {
        /// The key names no budgeted checker.
        case unknownChecker(String)
        /// The figure is not a positive, finite number of seconds within the maximum.
        case notABudget(checker: String, seconds: TimeInterval)

        /// What is wrong, and what would be accepted.
        public var errorDescription: String? {
            switch self {
            case .unknownChecker(let id):
                return "`budgets.\(id)` names no checker that has a time budget. Budgets apply to: "
                    + CheckerBudgetsConfig.budgetedCheckers.joined(separator: ", ") + "."
            case .notABudget(let checker, let seconds):
                return "`budgets.\(checker)` is \(seconds), and a budget is a number of seconds "
                    + "greater than zero and no more than \(ToolRun.figure(CheckerBudgetsConfig.maximumSeconds))."
            }
        }
    }

    /// Creates a validated set of budgets.
    ///
    /// - Parameter secondsByChecker: Budgets in seconds, by checker id.
    /// - Throws: ``Invalid`` for an id that names no budgeted checker, or a figure that is
    ///   not a positive finite number of seconds within ``maximumSeconds``.
    public init(_ secondsByChecker: [String: TimeInterval]) throws {
        for (checker, seconds) in secondsByChecker.sorted(by: { $0.key < $1.key }) {
            guard Self.budgetedCheckers.contains(checker) else {
                throw Invalid.unknownChecker(checker)
            }
            guard seconds.isFinite, seconds > 0, seconds <= Self.maximumSeconds else {
                throw Invalid.notABudget(checker: checker, seconds: seconds)
            }
        }
        self.secondsByChecker = secondsByChecker
    }

    private init(unchecked secondsByChecker: [String: TimeInterval]) {
        self.secondsByChecker = secondsByChecker
    }

    /// The configured budget for `checkerId`, or `nil` when none is set.
    public func seconds(for checkerId: String) -> TimeInterval? {
        secondsByChecker[checkerId]
    }
}

extension CheckerBudgetsConfig: Codable {
    /// Decodes a mapping of checker id to seconds, refusing an entry that is not a budget.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode([String: TimeInterval].self))
    }

    /// Encodes as the mapping it was read from.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(secondsByChecker)
    }
}
