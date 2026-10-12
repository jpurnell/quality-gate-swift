import Testing
@testable import QualityGateCore

/// Selection used to hold a denylist of destructive checkers (`disk-clean`) back from
/// `--check all` and from the default set. Cleanup has since moved off the
/// `QualityChecker` protocol to the `quality-gate clean` subcommand, so no registered
/// checker mutates the tree and selection carries no special cases beyond the slow
/// `xcode-build` opt-in. See `CheckerRegistryPurityTests`.
@Suite("CheckerSelection")
struct CheckerSelectionTests {
    // A representative registry order.
    private let allIDs = [
        "build", "safety", "unreachable", "logging", "hig-auditor", "xcode-build",
    ]

    @Test("--check all runs every registered checker")
    func allRunsEverything() {
        let result = CheckerSelection.resolve(
            requested: ["all"], excluded: [], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(result == allIDs)
    }

    @Test("--check all --exclude safety drops safety")
    func allWithExclude() {
        let result = CheckerSelection.resolve(
            requested: ["all"], excluded: ["safety"], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(!result.contains("safety"))
        #expect(result.contains("build"))
    }

    @Test("--check all preserves registry order")
    func allPreservesOrder() {
        let result = CheckerSelection.resolve(
            requested: ["all"], excluded: [], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(result == ["build", "safety", "unreachable", "logging", "hig-auditor", "xcode-build"])
    }

    @Test("explicit ids run exactly as requested")
    func explicitIDs() {
        let result = CheckerSelection.resolve(
            requested: ["safety"], excluded: [], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(result == ["safety"])
    }

    @Test("default set excludes the slow xcode-build checker")
    func defaultSet() {
        let result = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(!result.contains("xcode-build"))
        #expect(result.contains("build"))
        #expect(result.contains("safety"))
    }

    @Test("--full opts xcode-build back into the default set")
    func fullOptsInXcodeBuild() {
        let result = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: true, allIDs: allIDs
        )
        #expect(result == allIDs)
    }

    @Test("doc-code runs by default, now that the convention it holds articles to is adopted")
    func docCodeRunsByDefault() {
        // It was opt-in, and that was right at the time: the rule holds articles to being one
        // compilable program, and imposing it by surprise reported 76 true findings about
        // documentation nobody had agreed to write that way. The bar for promotion was
        // meeting the convention, not relaxing it — the catalogue now stands at 0 findings
        // with zero `<!-- docs:illustrative -->` markers, so the wall it was protecting
        // against no longer exists.
        let registry = allIDs + ["doc-code"]

        let byDefault = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: false, allIDs: registry
        )
        #expect(byDefault.contains("doc-code"))

        // `--exclude` is now the way out, and it has to keep working: a checker that cannot
        // be excluded is a checker that blocks a commit with no recourse.
        #expect(!CheckerSelection.resolve(
            requested: [], excluded: ["doc-code"], configuredEnabled: [], full: false, allIDs: registry
        ).contains("doc-code"))

        // `xcode-build` stays opt-in on cost, and `--full` remains the door for that alone.
        // The distinction outlives this promotion: `--full` means "the slow ones too", never
        // "adopt a documentation convention you have not adopted".
        #expect(!CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: false, allIDs: registry
        ).contains("xcode-build"))
        #expect(CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: true, allIDs: registry
        ).contains("xcode-build"))

        // Explicitly requested, and `--check all`, both still run it.
        #expect(CheckerSelection.resolve(
            requested: ["doc-code"], excluded: [], configuredEnabled: [], full: false, allIDs: registry
        ) == ["doc-code"])
        #expect(CheckerSelection.resolve(
            requested: ["all"], excluded: [], configuredEnabled: [], full: false, allIDs: registry
        ).contains("doc-code"))
    }

    @Test("doc-run and doc-claims are opt-in on a stronger convention still")
    func upperRungsAreOptIn() {
        // Rung 2 requires an article to *run* as one program, top to bottom, without a trap.
        // Rung 3 requires its documented figures to match what that program computes. Each is
        // red on arrival for a catalogue that has not done the remediation, and a gate that
        // is red on arrival gets skipped — which costs more than the rule buys.
        let registry = allIDs + ["doc-code", "doc-run", "doc-claims"]

        for rung in ["doc-run", "doc-claims"] {
            #expect(!CheckerSelection.resolve(
                requested: [], excluded: [], configuredEnabled: [], full: false, allIDs: registry
            ).contains(rung))
            #expect(!CheckerSelection.resolve(
                requested: [], excluded: [], configuredEnabled: [], full: true, allIDs: registry
            ).contains(rung))
            #expect(CheckerSelection.resolve(
                requested: [rung], excluded: [], configuredEnabled: [], full: false, allIDs: registry
            ) == [rung])
            #expect(CheckerSelection.resolve(
                requested: [], excluded: [], configuredEnabled: [rung], full: false, allIDs: registry
            ) == [rung])
        }
    }

    @Test("doc-comment-code is opt-in, and is not doc-code")
    func docCommentCodeIsOptIn() {
        // Two ids, on purpose. `doc-code` was made green at real cost, and sixteen of this
        // repository's twenty `///` fences failed the day `doc-comment-code` was measured.
        // A shared id would have turned the green one red on the day it landed, and a gate
        // that is red on arrival gets skipped.
        //
        // That separation earned its keep on 2026-08-27: `doc-comment-code` was promoted
        // into the default set and reverted the same night, when a sweep of all 86
        // gate-configured repositories found 12 red that the promoting survey had never
        // enumerated. `doc-code` stayed green throughout, because the ids are distinct.
        // This test is the guard on the revert.
        let registry = allIDs + ["doc-code", "doc-comment-code"]

        let byDefault = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: false, allIDs: registry
        )
        #expect(!byDefault.contains("doc-comment-code"))

        // `--full` means "the slow ones too" and never carried this. It must not be what
        // turns the checker on, or the flag quietly becomes a documentation-convention flag.
        let full = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: true, allIDs: registry
        )
        #expect(!full.contains("doc-comment-code"))

        // Enabling one must never enable the other.
        #expect(CheckerSelection.resolve(
            requested: ["doc-code"], excluded: [], configuredEnabled: [], full: false, allIDs: registry
        ) == ["doc-code"])
        #expect(CheckerSelection.resolve(
            requested: ["doc-comment-code"], excluded: [], configuredEnabled: [], full: false,
            allIDs: registry
        ) == ["doc-comment-code"])

        // And excluding one must never exclude the other, which a shared prefix would break
        // if selection ever moved to prefix matching.
        let allButComments = CheckerSelection.resolve(
            requested: ["all"], excluded: ["doc-comment-code"], configuredEnabled: [], full: false,
            allIDs: registry
        )
        #expect(allButComments.contains("doc-code"))
        #expect(!allButComments.contains("doc-comment-code"))
    }

    @Test("doc-generated is opt-in on convention, and --full does not adopt a convention")
    func docGeneratedIsOptIn() {
        // The cleanest case for the distinction `--full` draws. `xcode-build` opts out on
        // *cost*, so `--full` — "the slow ones too" — is the right lever for it.
        // `doc-generated` is fast; it opts out because a repository has to wrap a table in
        // delimiters before the verdict means anything, and that is a decision about the
        // document rather than a budget.
        let registry = allIDs + ["doc-generated"]

        let byDefault = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: false, allIDs: registry
        )
        #expect(!byDefault.contains("doc-generated"))

        let full = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: true, allIDs: registry
        )
        #expect(!full.contains("doc-generated"))

        // Asked for explicitly, or by `all`, it runs.
        #expect(CheckerSelection.resolve(
            requested: ["doc-generated"], excluded: [], configuredEnabled: [], full: false,
            allIDs: registry
        ) == ["doc-generated"])
        #expect(CheckerSelection.resolve(
            requested: ["all"], excluded: [], configuredEnabled: [], full: false, allIDs: registry
        ).contains("doc-generated"))

        // And `--exclude` is honoured against `all`, which is the escape hatch that keeps a
        // rule declinable without declining to run the gate.
        #expect(!CheckerSelection.resolve(
            requested: ["all"], excluded: ["doc-generated"], configuredEnabled: [], full: false,
            allIDs: registry
        ).contains("doc-generated"))
    }

    /// Three ids for one subject, because hermeticity is one value per checker. They do not
    /// share a default: the two that read only a file and the clock run everywhere, and the one
    /// that opens a connection runs when asked.
    @Test("dependency-advisory and its freshness run by default; the live comparison is opt-in")
    func advisoryDriftIsOptIn() {
        let registry = allIDs + [
            "dependency-advisory", "dependency-advisory-freshness", "dependency-advisory-drift",
        ]

        let byDefault = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: false, allIDs: registry
        )
        #expect(byDefault.contains("dependency-advisory"))
        #expect(byDefault.contains("dependency-advisory-freshness"))
        #expect(!byDefault.contains("dependency-advisory-drift"))

        // `--full` is the lever for cost, and a network round trip is not what it means.
        let full = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: true, allIDs: registry
        )
        #expect(!full.contains("dependency-advisory-drift"))

        // Asked for explicitly, or by `all`, it runs — and naming it selects it alone, which a
        // shared prefix would break if selection ever moved to prefix matching.
        #expect(CheckerSelection.resolve(
            requested: ["dependency-advisory-drift"], excluded: [], configuredEnabled: [], full: false,
            allIDs: registry
        ) == ["dependency-advisory-drift"])
        #expect(CheckerSelection.resolve(
            requested: ["dependency-advisory"], excluded: [], configuredEnabled: [], full: false,
            allIDs: registry
        ) == ["dependency-advisory"])
        #expect(CheckerSelection.resolve(
            requested: ["all"], excluded: [], configuredEnabled: [], full: false, allIDs: registry
        ).contains("dependency-advisory-drift"))
    }

    @Test("configured enabledCheckers are honored when no --check given")
    func configuredCheckers() {
        let result = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: ["safety", "logging"], full: false, allIDs: allIDs
        )
        #expect(result == ["safety", "logging"])
    }

    @Test("--exclude is honoured in a default run, not only under --check all")
    func excludeAppliesToDefaultRun() {
        // It used to apply only to `--check all`, and the CLI help said so. That was
        // survivable while every default-set checker was one you wanted; it stopped being
        // survivable the moment a checker was promoted into that set, because the obvious
        // way to decline it did nothing and said nothing.
        let byDefault = CheckerSelection.resolve(
            requested: [], excluded: ["logging"], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(!byDefault.contains("logging"))
        #expect(byDefault.contains("safety"))
    }

    @Test("excludedCheckers declines a default-on checker, but not an explicit --check")
    func configuredExclusionAppliesToDefaultsNotToExplicitRequests() {
        // The config form of `--exclude`, unioned with the flag by the CLI. It exists for a
        // package the checker cannot evaluate at all — Ignite, whose fence compile stops at
        // a missing `cmark_gfm_extensions` before any fence is read — so the fact can be
        // stated once in writing rather than relying on every invocation carrying a flag.
        let registry = allIDs + ["doc-comment-code"]

        let byDefault = CheckerSelection.resolve(
            requested: [], excluded: ["doc-comment-code"], configuredEnabled: [], full: false,
            allIDs: registry
        )
        #expect(!byDefault.contains("doc-comment-code"))
        #expect(byDefault.contains("safety"))

        // But naming it explicitly is a request to see what it says, and a config file must
        // not be able to silently refuse that — otherwise the excluded package becomes
        // unexaminable, and the exclusion stops being reviewable.
        #expect(CheckerSelection.resolve(
            requested: ["doc-comment-code"], excluded: ["doc-comment-code"], configuredEnabled: [],
            full: false, allIDs: registry
        ) == ["doc-comment-code"])
    }

    @Test("--exclude is honoured against configured enabledCheckers")
    func excludeAppliesToConfiguredSet() {
        // Same hole, same reason: a flag that silently does nothing in two of four selection
        // modes is worse than one that is absent, because absence is discoverable.
        let result = CheckerSelection.resolve(
            requested: [], excluded: ["safety"], configuredEnabled: ["build", "safety"],
            full: false, allIDs: allIDs
        )
        #expect(result == ["build"])
    }

    // MARK: - includedCheckers

    @Test("includedCheckers opts one checker into the default set, and nothing else")
    func includedOptsInto() {
        // The opt-in the default set lacked. `enabledCheckers: [all]` was the only config
        // route to `xcode-build`, and it also enabled every convention-gated doc checker —
        // each red on arrival for a catalogue that has not adopted its convention.
        let registry = allIDs + ["doc-run", "doc-comment-code"]
        let result = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], configuredIncluded: ["xcode-build"],
            full: false, allIDs: registry
        )
        #expect(result.contains("xcode-build"))
        #expect(result.contains("safety"))
        #expect(!result.contains("doc-run"))
        #expect(!result.contains("doc-comment-code"))
    }

    @Test("includedCheckers preserves registry order")
    func includedPreservesOrder() {
        let result = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], configuredIncluded: ["xcode-build"],
            full: false, allIDs: allIDs
        )
        #expect(result == allIDs)
    }

    @Test("an exclusion still wins over an inclusion")
    func exclusionWinsOverInclusion() {
        // The escape hatch has to stay load-bearing: `--exclude xcode-build` must work in a
        // repository whose config opts it in.
        let result = CheckerSelection.resolve(
            requested: [], excluded: ["xcode-build"], configuredEnabled: [],
            configuredIncluded: ["xcode-build"], full: false, allIDs: allIDs
        )
        #expect(!result.contains("xcode-build"))
    }

    @Test("includedCheckers adds to a configured enabledCheckers list")
    func includedUnionsWithEnabled() {
        let result = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: ["build", "safety"],
            configuredIncluded: ["xcode-build", "safety"], full: false, allIDs: allIDs
        )
        #expect(result == ["build", "safety", "xcode-build"])
    }

    @Test("includedCheckers changes neither --check all nor an explicit --check")
    func includedLeavesExplicitRequestsAlone() {
        #expect(CheckerSelection.resolve(
            requested: ["safety"], excluded: [], configuredEnabled: [], configuredIncluded: ["xcode-build"],
            full: false, allIDs: allIDs
        ) == ["safety"])
        #expect(CheckerSelection.resolve(
            requested: ["all"], excluded: [], configuredEnabled: [], configuredIncluded: ["xcode-build"],
            full: false, allIDs: allIDs
        ) == allIDs)
    }

    // MARK: - Comma lists

    @Test("--check a,b means --check a b")
    func commaListIsSplit() {
        // `coding_rules.md` documents the security audit as
        // `--check safety,fp-safety,stochastic-determinism`. ArgumentParser delivers that
        // as one string, which matched no checker id and ran nothing, exiting 0.
        #expect(CheckerSelection.resolve(
            requested: ["safety,logging"], excluded: [], configuredEnabled: [], full: false,
            allIDs: allIDs
        ) == ["safety", "logging"])
    }

    @Test("the all sentinel survives splitting")
    func allSurvivesSplitting() {
        #expect(CheckerSelection.resolve(
            requested: ["all,build"], excluded: [], configuredEnabled: [], full: false, allIDs: allIDs
        ) == allIDs)
    }

    @Test("a comma list in --exclude and in enabledCheckers is split the same way")
    func commaListIsSplitEverywhere() {
        #expect(CheckerSelection.resolve(
            requested: ["all"], excluded: ["safety,logging"], configuredEnabled: [], full: false,
            allIDs: allIDs
        ) == ["build", "unreachable", "hig-auditor", "xcode-build"])
        #expect(CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: ["build, safety"], full: false,
            allIDs: allIDs
        ) == ["build", "safety"])
    }
}
