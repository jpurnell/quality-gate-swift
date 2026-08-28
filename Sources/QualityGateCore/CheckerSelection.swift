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
    ///   - excluded: Values from `--exclude`, plus `Configuration.excludedCheckers`. The
    ///     two are unioned by the caller because they mean the same thing; the config form
    ///     exists so a repository the checker cannot evaluate can say so once, in writing,
    ///     instead of relying on every invocation remembering a flag.
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
            // `all` means the same thing here as it does on the command line. Without this
            // the obvious repair for a dropped `enabledCheckers` key —
            //
            //     enabledCheckers:
            //       - all
            //
            // returns ["all"], matches no checker id, and runs *nothing*, silently. A
            // reader correcting one invisible misconfiguration would land one step deeper
            // into the same failure, and the run would still print PASSED.
            if configuredEnabled.contains("all") {
                return allIDs.filter { !excludeSet.contains($0) }
            }
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
            // `doc-comment-code` is opt-in. It was promoted into the default set on
            // 2026-08-27 and reverted the same night, and the reason is worth more than the
            // one-line diff: the promotion was justified by a survey that did not cover the
            // fleet it claimed to.
            //
            // What the promoting commit recorded was "39 gate-configured repositories
            // surveyed, 5 red, 60 errors, all repaired first". The number 39 was real; the
            // word "all" was not. The survey globbed `Swift/*/.quality-gate.yml` — one
            // directory, one level deep — while `find` over the same tree returns 86. The
            // 47 it missed were every repository living in a subdirectory: `Tools/`,
            // `harbor/`, `Playgrounds/Math/`, `Embedded/`, `Princeton/`.
            //
            // That blind spot was not random with respect to the answer. A full sweep after
            // the flip found 12 red repositories carrying 162 errors, and every single one
            // of them was in a subdirectory — five in `Tools/`, which is where this package
            // itself lives. The sampled 39 were green precisely because they were the
            // top-level packages that had already had attention paid to them.
            //
            // So the bar `doc-code` met is unchanged and still right — adopt the convention
            // by repairing the documentation, never by relaxing the rule. This rule has not
            // met it yet. Re-promoting takes a survey enumerated with `find`, not a glob,
            // and the 12 reds repaired first. Three of them (`BusinessMathPro`,
            // `swift-potrace`, `sicp-swift-companion`) are already done and stay done.
            //
            // Two findings from that sweep outlived the revert and are the reason it was
            // not a total loss:
            //
            // First, a survey run as `--check doc-comment-code` does not run `build`, and
            // this checker compiles against a built module rather than building one — so
            // every cold-`.build` repository reports SKIPPED and reads as clean. Three
            // "clean" repositories were red once `build` ran first. That is why
            // `module-unavailable` is now a warning rather than a note, and why any future
            // survey must invoke `--check build --check doc-comment-code`.
            //
            // Second, one repository cannot be evaluated at all. `Ignite` depends on
            // swift-markdown, whose C target `cmark_gfm_extensions` the fence compile cannot
            // reach; compilation stops at that barrier before a single fence is read, and
            // 16 of its 17 findings are that barrier restated. Its docs are not implicated.
            // It carries `excludedCheckers: [doc-comment-code]` until the fence compile
            // learns to feed a package's C-target module maps to the compiler — which is the
            // real fix, and is not this change. That entry stays load-bearing even while the
            // rule is opt-in, because `--check all` still selects it and the pre-push hook
            // runs `--check all`.
            //
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
