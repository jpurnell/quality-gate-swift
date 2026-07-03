import Testing
@testable import QualityGateCore

@Suite("CheckerSelection")
struct CheckerSelectionTests {
    // A representative registry order including the destructive maintenance checker.
    private let allIDs = [
        "build", "safety", "unreachable", "logging", "hig-auditor",
        "xcode-build", "disk-clean",
    ]

    @Test("--check all excludes disk-clean (destructive, opt-in)")
    func allExcludesDiskClean() {
        let result = CheckerSelection.resolve(
            requested: ["all"], excluded: [], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(!result.contains("disk-clean"), "disk-clean must not run under --check all")
        #expect(result.contains("safety"))
        #expect(result.contains("hig-auditor"))
        #expect(result.contains("xcode-build"), "non-destructive checkers still run under all")
    }

    @Test("--check all --check disk-clean opts disk-clean back in")
    func allPlusExplicitDiskClean() {
        let result = CheckerSelection.resolve(
            requested: ["all", "disk-clean"], excluded: [], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(result.contains("disk-clean"), "explicitly named maintenance checker runs under all")
    }

    @Test("--check disk-clean runs it explicitly")
    func explicitDiskCleanOnly() {
        let result = CheckerSelection.resolve(
            requested: ["disk-clean"], excluded: [], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(result == ["disk-clean"])
    }

    @Test("--check all --exclude safety drops safety")
    func allWithExclude() {
        let result = CheckerSelection.resolve(
            requested: ["all"], excluded: ["safety"], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(!result.contains("safety"))
        #expect(!result.contains("disk-clean"))
        #expect(result.contains("build"))
    }

    @Test("--check all preserves registry order")
    func allPreservesOrder() {
        let result = CheckerSelection.resolve(
            requested: ["all"], excluded: [], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(result == ["build", "safety", "unreachable", "logging", "hig-auditor", "xcode-build"])
    }

    @Test("default set excludes disk-clean and xcode-build")
    func defaultSet() {
        let result = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: false, allIDs: allIDs
        )
        #expect(!result.contains("disk-clean"))
        #expect(!result.contains("xcode-build"))
        #expect(result.contains("build"))
    }

    @Test("--full opts xcode-build back into the default set but not disk-clean")
    func fullOptsInXcodeBuildOnly() {
        let result = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: [], full: true, allIDs: allIDs
        )
        #expect(result.contains("xcode-build"))
        #expect(!result.contains("disk-clean"), "disk-clean stays opt-in even with --full")
    }

    @Test("configured enabledCheckers are honored when no --check given")
    func configuredCheckers() {
        let result = CheckerSelection.resolve(
            requested: [], excluded: [], configuredEnabled: ["safety", "logging"], full: false, allIDs: allIDs
        )
        #expect(result == ["safety", "logging"])
    }
}
