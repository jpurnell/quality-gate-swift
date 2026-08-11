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
}
