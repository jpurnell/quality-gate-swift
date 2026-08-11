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
            return configuredEnabled
        } else {
            // Default (no --check, no config): everything except the opt-in checkers.
            //
            // `xcode-build` opts out on cost. `doc-code` opts out on *convention*: it holds
            // an article to being one compilable program, which is a rule a repository has to
            // adopt before the verdict means anything. Imposed by default it would report a
            // wall of true findings about documentation nobody had agreed to write that way —
            // and a gate that is red on arrival gets skipped, which costs more than the rule
            // buys. Opt in with `--check doc-code` or `enabledCheckers`, and note that `--full`
            // deliberately does *not* enable it: `--full` means "the slow ones too", not "adopt
            // a documentation convention you have not adopted".
            //
            // `doc-run` and `doc-claims` opt out on a *stronger* convention still. Rung 2
            // requires an article to run as one program, top to bottom, without a trap;
            // rung 3 requires its documented figures to match what that program computes.
            // Each is red on arrival for a catalogue that has not done the remediation, and
            // the rollout shape that works is rule-and-remediation in one push.
            var optOut: Set<String> = ["xcode-build", "doc-code", "doc-run", "doc-claims"]
            if full { optOut.remove("xcode-build") }
            return allIDs.filter { !optOut.contains($0) }
        }
    }
}
