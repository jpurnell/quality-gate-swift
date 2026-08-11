import Foundation

/// Resolves which checkers should run for a given invocation.
///
/// Extracted from the CLI so the selection rules are unit-testable and consistent
/// across entry points.
///
/// ## No destructive checkers
///
/// Selection no longer carries a denylist of tree-mutating checkers. Cleanup moved to the
/// `quality-gate clean` subcommand and off the `QualityChecker` protocol entirely, so
/// "run all checks" is non-destructive because nothing registered can mutate the tree —
/// not because a hardcoded set of ids is held back. See `DiskCleaner`.
public enum CheckerSelection {

    /// Resolve the ordered list of checker ids to run.
    ///
    /// - Parameters:
    ///   - requested: Values from `--check`. May contain the sentinel `"all"` and/or
    ///     explicit checker ids.
    ///   - excluded: Values from `--exclude`.
    ///   - configuredEnabled: `Configuration.enabledCheckers` (from `.quality-gate.yml`).
    ///   - full: The `--full` flag; opts `xcode-build` back into the default set.
    ///   - allIDs: All registered checker ids, in registry (output) order.
    /// - Returns: The checker ids to run, preserving `allIDs` order where applicable.
    public static func resolve(
        requested: [String],
        excluded: [String],
        configuredEnabled: [String],
        full: Bool,
        allIDs: [String]
    ) -> [String] {
        let excludeSet = Set(excluded)

        if requested.contains("all") {
            return allIDs.filter { !excludeSet.contains($0) }
        } else if !requested.isEmpty {
            // Explicit ids run as requested.
            return requested
        } else if !configuredEnabled.isEmpty {
            return configuredEnabled.filter { !excludeSet.contains($0) }
        } else {
            // Default (no --check, no config): everything except the opt-in checkers.
            //
            // `xcode-build` opts out on cost.
            //
            // `doc-code` used to opt out on *convention*, and the reasoning is kept here
            // rather than deleted, because it was right at the time: the rule holds an
            // article to being one compilable program, which a repository has to adopt
            // before the verdict means anything. Imposed by default it reported a wall of
            // true findings about documentation nobody had agreed to write that way — 76 of
            // them against this package — and a gate that is red on arrival gets skipped,
            // which costs more than the rule buys.
            //
            // That bar has now been met, which is why it is default-on: the catalogue is at
            // 0 findings across 50 articles and 152 fences, with **zero**
            // `<!-- docs:illustrative -->` markers. The convention was adopted by repairing
            // the documentation, not by lowering the rule. Note that the wall of 76 was also
            // partly the checker's own fault — it was silently failing to typecheck anything
            // at all until the module-import barrier was fixed, so some of what looked like
            // convention cost was a tooling defect wearing its costume.
            //
            // `--full` still deliberately does not carry a documentation convention; it means
            // "the slow ones too". That distinction outlives this promotion.
            var optOut: Set<String> = ["xcode-build"]
            if full { optOut.remove("xcode-build") }
            // `--exclude` is honoured here too, which it was not before. While `doc-code` was
            // opt-in that gap was invisible: nothing in the default set was worth excluding,
            // so `quality-gate --exclude doc-code` silently doing nothing cost nobody
            // anything. Promoting a checker into the default set is exactly what makes the
            // escape hatch load-bearing — a rule you cannot decline with the obvious flag is
            // a rule that gets declined by not running the gate.
            return allIDs.filter { !optOut.contains($0) && !excludeSet.contains($0) }
        }
    }
}
