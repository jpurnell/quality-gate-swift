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
            // `doc-run` and `doc-claims` stay opt-in on a *stronger* convention still. Rung 2
            // requires an article to run as one program, top to bottom, without a trap;
            // rung 3 requires its documented figures to match what that program computes.
            // Each is red on arrival for a catalogue that has not done the remediation, and
            // the rollout shape that works is rule-and-remediation in one push — which is
            // exactly the shape `doc-code` has just finished walking, so the precedent for
            // promoting them later is now on the record rather than hypothetical.
            //
            // `doc-comment-code` also stays opt-in, though its number has already moved: 16
            // of this repository's 20 `///` fences failed the day the rule was written — 10
            // of them one `## Usage` template copied into ten auditors — and all 16 are now
            // repaired, with no exemptions. It carries its own id rather than sharing
            // `doc-code`'s precisely so that landing it red could not take a green `doc-code`
            // down with it, and that separation is worth keeping now that the ids can be
            // promoted independently. Promoting it is a separate decision on the same terms
            // `doc-code` met, and the terms are the point: adopt the convention by repairing
            // the documentation, never by relaxing the rule.
            //
            // `--full` still deliberately does not carry a documentation convention; it means
            // "the slow ones too". That distinction outlives this promotion.
            // `doc-generated` opts out on convention alone, and it is the cleanest case for
            // the distinction the paragraph above draws: the checker is *fast*, so cost is
            // not the reason. A repository with no `<!-- generated: -->` delimiters anywhere
            // gets nothing from it and should not pay for discovering that. Adopting the
            // convention means wrapping a table in delimiters, which is a decision about the
            // document, not a setting.
            var optOut: Set<String> = [
                "xcode-build", "doc-run", "doc-claims", "doc-comment-code", "doc-generated",
            ]
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
