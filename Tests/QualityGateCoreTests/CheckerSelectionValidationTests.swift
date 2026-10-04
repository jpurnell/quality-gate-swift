import Testing
@testable import QualityGateCore

/// A selection the gate cannot honour is an error, not a no-op.
///
/// `--check a,b` used to deliver the single id `"a,b"`, match nothing, print
/// `No checkers enabled. Nothing to do.` and exit 0 — and the same path swallowed a typo,
/// dropped one bad id from a good list, and ignored a typo in `enabledCheckers`.
@Suite("CheckerSelection validation")
struct CheckerSelectionValidationTests {

    private let allIDs = [
        "build", "safety", "recursion", "fp-safety", "fallback", "logging", "consistency",
        "xcode-build",
    ]

    private func select(
        requested: [String] = [],
        excluded: [String] = [],
        configuredEnabled: [String] = [],
        configuredExcluded: [String] = [],
        configuredIncluded: [String] = [],
        profileBase: [String]? = nil
    ) throws -> CheckerSelection.Selection {
        try CheckerSelection.select(
            CheckerSelection.Request(
                requested: requested,
                excluded: excluded,
                configuredEnabled: configuredEnabled,
                configuredExcluded: configuredExcluded,
                configuredIncluded: configuredIncluded,
                full: false,
                profileBase: profileBase),
            allIDs: allIDs)
    }

    // MARK: - Normalise

    @Test("values are split on commas, trimmed, and empty tokens dropped")
    func normalise() {
        #expect(CheckerSelection.normalise(["fp-safety,fallback"]) == ["fp-safety", "fallback"])
        #expect(CheckerSelection.normalise(["a, b"]) == ["a", "b"])
        #expect(CheckerSelection.normalise(["a,,b"]) == ["a", "b"])
        #expect(CheckerSelection.normalise(["a,"]) == ["a"])
        #expect(CheckerSelection.normalise(["a", "b,c", " d "]) == ["a", "b", "c", "d"])
        #expect(CheckerSelection.normalise([",", ""]) == [])
    }

    @Test("--check a,b / --check a b / --check a --check b select the same checkers")
    func threeSpellingsOneSelection() throws {
        let comma = try select(requested: ["fp-safety,fallback"])
        let spaced = try select(requested: ["fp-safety", "fallback"])
        #expect(comma.ids == ["fp-safety", "fallback"])
        #expect(comma == spaced)
    }

    @Test("the all sentinel survives splitting")
    func allSurvivesSplitting() throws {
        #expect(try select(requested: ["all,build"]).ids == allIDs)
    }

    // MARK: - Unknown ids

    @Test("an unknown id in --check is refused")
    func unknownRequestedIsRefused() {
        #expect(throws: CheckerSelectionError.unknownCheckers(["bogus"], suggestions: [:])) {
            try select(requested: ["bogus"])
        }
    }

    @Test("a near miss is refused with the id it probably meant")
    func nearMissSuggests() {
        #expect(throws: CheckerSelectionError.unknownCheckers(
            ["recursoin"], suggestions: ["recursoin": "recursion"])
        ) {
            try select(requested: ["recursoin"])
        }
        #expect(throws: CheckerSelectionError.unknownCheckers(
            ["fp-safty"], suggestions: ["fp-safty": "fp-safety"])
        ) {
            try select(requested: ["fp-safty"])
        }
    }

    @Test("one unknown id among good ones refuses the whole selection")
    func noPartialSelection() {
        // "Ran 2 of the 3 I asked for and passed" is the silent drop.
        #expect(throws: CheckerSelectionError.unknownCheckers(["bogus"], suggestions: [:])) {
            try select(requested: ["recursion", "bogus"])
        }
        #expect(throws: CheckerSelectionError.unknownCheckers(["bogus"], suggestions: [:])) {
            try select(requested: ["recursion,bogus"])
        }
    }

    @Test("an unknown id in --exclude is refused")
    func unknownExcludedIsRefused() {
        #expect(throws: CheckerSelectionError.unknownExclusions(["bogus"], suggestions: [:])) {
            try select(requested: ["recursion"], excluded: ["bogus"])
        }
        #expect(throws: CheckerSelectionError.unknownExclusions(
            ["loging"], suggestions: ["loging": "logging"])
        ) {
            try select(excluded: ["loging"])
        }
    }

    @Test("an unknown id in enabledCheckers is a configuration error, not a usage error")
    func unknownConfiguredIsAConfigurationError() {
        let expected = CheckerSelectionError.unknownConfigured(
            ["recursoin"], key: "enabledCheckers", suggestions: ["recursoin": "recursion"])
        #expect(throws: expected) {
            try select(configuredEnabled: ["recursoin"])
        }
        #expect(expected.exitCode == 1)
        #expect(!expected.isUsageError)
        #expect(expected.message.contains("enabledCheckers names 'recursoin', which is not a checker"))
    }

    @Test("enabledCheckers is validated only when it is what selects")
    func configuredEnabledIsNotConsultedUnderAnExplicitCheck() throws {
        // `--check` overrides the configured list entirely; a request the arguments fully
        // specify is not refused over a list it never read.
        #expect(try select(requested: ["recursion"], configuredEnabled: ["recursoin"]).ids == ["recursion"])
    }

    @Test("an unknown id in excludedCheckers or includedCheckers is noticed, not fatal")
    func unknownConfiguredExclusionIsNoticed() throws {
        let selection = try select(
            requested: ["all"], configuredExcluded: ["retired-long-ago"], configuredIncluded: ["nope"])
        #expect(selection.ids == allIDs)
        #expect(selection.notices.count == 2)
        #expect(selection.notices.contains { $0.contains("excludedCheckers") && $0.contains("'retired-long-ago'") })
        #expect(selection.notices.contains { $0.contains("includedCheckers") && $0.contains("'nope'") })
    }

    // MARK: - Retired ids

    @Test("a retired id in --check names its replacement")
    func retiredRequestedNamesReplacement() {
        let expected = CheckerSelectionError.retired("disk-clean", replacement: "quality-gate clean")
        #expect(throws: expected) {
            try select(requested: ["disk-clean"])
        }
        #expect(throws: expected) {
            try select(configuredEnabled: ["build", "disk-clean"])
        }
        #expect(expected.message.contains("`--check disk-clean` has moved: run `quality-gate clean` instead."))
    }

    @Test("a retired id in --exclude or excludedCheckers is accepted with a notice")
    func retiredExcludedIsAccepted() throws {
        // `scripts/onboard-corpus.sh` passes `--exclude disk-clean`. Excluding something
        // that no longer exists does no harm.
        let byFlag = try select(requested: ["all"], excluded: ["disk-clean"])
        #expect(byFlag.ids == allIDs)
        #expect(byFlag.notices.count == 1)
        #expect(byFlag.notices.first?.contains("'disk-clean'") == true)
        #expect(byFlag.notices.first?.contains("quality-gate clean") == true)

        let byConfig = try select(configuredExcluded: ["disk-clean"])
        #expect(byConfig.notices.count == 1)
        #expect(!byConfig.ids.isEmpty)
    }

    // MARK: - Empty selection

    @Test("--check X --exclude X is an empty selection caused by the arguments")
    func checkThenExcludeIsEmpty() {
        let expected = CheckerSelectionError.emptySelection(.allExcluded)
        #expect(throws: expected) {
            try select(requested: ["recursion"], excluded: ["recursion"])
        }
        #expect(expected.exitCode == 64)
        #expect(expected.isUsageError)
    }

    @Test("--exclude narrows an explicit --check")
    func excludeNarrowsExplicit() throws {
        #expect(try select(requested: ["recursion", "logging"], excluded: ["logging"]).ids == ["recursion"])
    }

    @Test("excludedCheckers does not refuse an explicit --check")
    func configuredExclusionDoesNotRefuseExplicit() throws {
        // Naming a checker is a request to see what it says; a config file must not be able
        // to silently refuse that. See `configuredExclusionAppliesToDefaultsNotToExplicitRequests`.
        #expect(try select(requested: ["recursion"], configuredExcluded: ["recursion"]).ids == ["recursion"])
    }

    @Test("a configuration that excludes everything is an empty selection caused by configuration")
    func configurationExcludingEverythingIsEmpty() {
        let expected = CheckerSelectionError.emptySelection(.configuration)
        #expect(throws: expected) {
            try select(configuredEnabled: ["build"], configuredExcluded: ["build"])
        }
        #expect(throws: expected) {
            try select(requested: ["all"], configuredExcluded: allIDs)
        }
        #expect(expected.exitCode == 1)
        #expect(!expected.isUsageError)
    }

    @Test("a profile that matches nothing is an empty selection caused by the profile")
    func profileMatchingNothingIsEmpty() {
        let expected = CheckerSelectionError.emptySelection(.profile)
        #expect(throws: expected) {
            try select(profileBase: [])
        }
        #expect(expected.exitCode == 1)
        // …but excluding everything a profile did match is the arguments' doing.
        #expect(throws: CheckerSelectionError.emptySelection(.allExcluded)) {
            try select(excluded: ["build"], profileBase: ["build"])
        }
    }

    @Test("consistency alone is a valid, non-empty selection")
    func consistencyAloneIsValid() throws {
        #expect(try select(requested: ["consistency"]).ids == ["consistency"])
    }

    // MARK: - Profile composition

    @Test("a profile supplies the base; --check adds and --exclude removes, in registry order")
    func profileComposes() throws {
        let selection = try select(
            requested: ["xcode-build"], excluded: ["safety"], profileBase: ["safety", "recursion", "build"])
        #expect(selection.ids == ["build", "recursion", "xcode-build"])
    }

    // MARK: - Messages and exit codes

    @Test("usage errors exit 64 and say what was asked for")
    func usageErrorMessages() {
        let unknown = CheckerSelectionError.unknownCheckers(
            ["recursoin"], suggestions: ["recursoin": "recursion"])
        #expect(unknown.exitCode == 64)
        #expect(unknown.message.contains("--check 'recursoin' names no checker. Did you mean 'recursion'?"))

        let bare = CheckerSelectionError.unknownCheckers(["bogus"], suggestions: [:])
        #expect(bare.message.contains("--check 'bogus' names no checker."))
        #expect(!bare.message.contains("Did you mean"))
        #expect(bare.message.contains("quality-gate doctor"))

        let exclusion = CheckerSelectionError.unknownExclusions(["bogus"], suggestions: [:])
        #expect(exclusion.exitCode == 64)
        #expect(exclusion.message.contains("--exclude 'bogus' names no checker."))

        #expect(CheckerSelectionError.retired("disk-clean", replacement: "quality-gate clean").exitCode == 1)
    }
}
