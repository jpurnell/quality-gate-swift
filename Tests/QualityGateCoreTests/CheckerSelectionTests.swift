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

    @Test("doc-code is opt-in, and --full does not opt it in")
    func docCodeIsOptIn() {
        // `--full` means "run the slow ones too". `doc-code` is not merely slow — it holds
        // articles to a convention a repository has to adopt first, so enabling it by
        // surprise would report true findings about documentation nobody agreed to write
        // that way.
        let registry = allIDs + ["doc-code"]

        let byDefault = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: false, allIDs: registry
        )
        #expect(!byDefault.contains("doc-code"))

        let full = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: true, allIDs: registry
        )
        #expect(!full.contains("doc-code"))
        #expect(full.contains("xcode-build"))

        // Explicitly requested, and `--check all`, both run it.
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
}
