import Foundation
import Testing
@testable import QualityGateCore

/// Problem B of `quality-gate-swift-project/plans/proposals/CheckerAutoDiscovery.md`: an unrecognized
/// `.quality-gate.yml` key is a finding now, not a silent discard. Expected values are written by hand from the
/// schema's own known keys.
@Suite("UnknownConfigurationKeys")
struct UnknownConfigurationKeysTests {

    // MARK: the real, dated incident

    @Test("the real incident: SwiftPenTest's superseded top-level keys are caught, naming the real replacements")
    func theRealSwiftPenTestIncident() throws {
        // This is not invented: `exclude`/`checkers` instead of `excludedCheckers`/`enabledCheckers` is the exact
        // pair a 2026-08-25 survey found in 11 of 73 repositories scaffolded from this tool, documented in
        // SwiftPenTest's own `.quality-gate.yml`. Before this change, both were silently discarded during
        // decoding and the gate ran its defaults with no sign anything was wrong.
        let configuration = try Configuration.from(yaml: """
            exclude:
              - disk-clean
            checkers:
              - all
              - logging
            """)
        let unknown = try #require(configuration.unknownKeys)
        #expect(unknown.keys == ["checkers", "exclude"])
        let suggested = Dictionary(uniqueKeysWithValues: unknown.suggestions)
        #expect(suggested["checkers"] == "enabledCheckers")
        #expect(suggested["exclude"] == "excludedCheckers")
    }

    @Test("a config with every key spelled correctly carries no finding")
    func everyKeyKnownIsClean() throws {
        let configuration = try Configuration.from(yaml: """
            enabledCheckers:
              - all
            excludedCheckers:
              - disk-clean
            """)
        #expect(configuration.unknownKeys == nil)
    }

    // MARK: nested sections

    @Test("an unrecognized key inside status: is caught, qualified by section")
    func statusSectionUnknownKey() throws {
        let configuration = try Configuration.from(yaml: """
            enabledCheckers: []
            status:
              guidlinesPath: "."
            """)
        let unknown = try #require(configuration.unknownKeys)
        #expect(unknown.keys == ["status.guidlinesPath"])
        #expect(Dictionary(uniqueKeysWithValues: unknown.suggestions)["status.guidlinesPath"] == "status.guidelinesPath")
    }

    @Test("an unrecognized key inside consistency: is caught")
    func consistencySectionUnknownKey() throws {
        let configuration = try Configuration.from(yaml: """
            enabledCheckers: []
            consistency:
              corpusPath: "/tmp/corpus"
              threshhold: 0.5
            """)
        let unknown = try #require(configuration.unknownKeys)
        #expect(unknown.keys == ["consistency.threshhold"])
    }

    @Test("an unrecognized key inside ijs: is caught — this is the schema's own documented BusinessMath shape")
    func ijsSectionUnknownKey() throws {
        let configuration = try Configuration.from(yaml: """
            enabledCheckers: []
            ijs:
              projectID: "x"
              corpusPth: "/tmp/corpus"
            """)
        let unknown = try #require(configuration.unknownKeys)
        #expect(unknown.keys == ["ijs.corpusPth"])
        #expect(Dictionary(uniqueKeysWithValues: unknown.suggestions)["ijs.corpusPth"] == "ijs.corpusPath")
    }

    @Test("a correctly spelled nested section carries no finding, even with every field set")
    func nestedSectionsFullyValidAreClean() throws {
        let configuration = try Configuration.from(yaml: """
            enabledCheckers: []
            status:
              guidelinesPath: "."
              masterPlanPath: "project/master_plan.md"
            consistency:
              corpusPath: "/tmp/corpus"
              projectID: "x"
            ijs:
              projectID: "x"
              corpusPath: "/tmp/corpus"
              decisionOwner: "me"
            """)
        #expect(configuration.unknownKeys == nil)
    }

    @Test("top level and two nested sections all misspelled: every one is reported, none hides another")
    func multipleSectionsAllReported() throws {
        let configuration = try Configuration.from(yaml: """
            exclude: []
            status:
              guidlinesPath: "."
            ijs:
              corpusPth: "/tmp"
            """)
        let unknown = try #require(configuration.unknownKeys)
        #expect(Set(unknown.keys) == ["exclude", "status.guidlinesPath", "ijs.corpusPth"])
    }

    // MARK: edit-distance suggestion correctness

    @Test("the suggestion is the nearest known key, not an arbitrary one, for several real misspellings", arguments: [
        ("exclud", "excludedCheckers"),
        ("enabledChecker", "enabledCheckers"),
        ("checkers", "enabledCheckers"),
        ("exclude", "excludedCheckers"),
    ])
    func nearestSuggestionIsCorrect(written: String, expected: String) {
        let known: Set<String> = ["enabledCheckers", "excludedCheckers", "includedCheckers", "buildConfiguration"]
        #expect(UnknownConfigurationKeys.nearestKey(to: written, in: known) == expected)
    }

    @Test("nothing close enough gets no suggestion, rather than a wrong one")
    func noSuggestionWhenNothingIsClose() {
        let known: Set<String> = ["enabledCheckers", "excludedCheckers"]
        #expect(UnknownConfigurationKeys.nearestKey(to: "completelyUnrelatedWord", in: known) == nil)
    }

    @Test("two keys equally containing the written one, with no documented rename to break the tie, get no suggestion — not the shorter one by chance")
    func genuinelyAmbiguousContainmentRefusesRatherThanGuesses() {
        // Neither candidate is `exclude`/`checkers`, so `documentedRenames` does not apply here: this is the
        // containment tie-break itself being exercised, on a pair of keys invented for this test, not real ones.
        let known: Set<String> = ["statusReport", "statusChecker"]
        #expect(UnknownConfigurationKeys.nearestKey(to: "status", in: known) == nil)
    }

    // MARK: merge

    @Test("merging is deterministic: same inputs, same order, every time")
    func mergeIsDeterministic() {
        let a = UnknownConfigurationKeys(keys: ["x"], suggestions: [(written: "x", suggested: "excludedCheckers")])
        let b = UnknownConfigurationKeys(keys: ["status.y"], suggestions: [])
        let first = UnknownConfigurationKeys.merge([a, nil, b])
        let second = UnknownConfigurationKeys.merge([a, nil, b])
        #expect(first == second)
        #expect(first?.keys == ["x", "status.y"])
    }

    @Test("merging all-nil is nil")
    func mergeAllNilIsNil() {
        #expect(UnknownConfigurationKeys.merge([nil, nil, nil]) == nil)
    }
}
