import Foundation
import Testing
@testable import QualityGateCore

/// The pattern-structure analyser behind `security.regex-catastrophic` (`APatternIsAProgram.md`
/// §4.1).
///
/// Contract under test: a group quantified by `+`, `*` or `{n,}` is catastrophic when (a) one of
/// its alternatives holds, at its top level, an atom quantified the same way and no mandatory
/// literal; or (b) two of its alternatives are identical, one is a literal prefix of the other, or
/// both are single characters from overlapping classes. A possessive inner quantifier or an
/// atomic group clears it; so does escaping, and so does being inside a character class.
@Suite("RegexStructure")
struct RegexStructureTests {

    @Test("nested unbounded repetition is found, naming the group", arguments: [
        ("(a+)+$", "(a+)+"),
        (#"(\w+\s?)*$"#, #"(\w+\s?)*"#),
        (#"(\s*\w+)*"#, #"(\s*\w+)*"#),
        ("([a-z]+)*", "([a-z]+)*"),
        // Measured harmless on ICU at n ≤ 22 (§2) and flagged anyway: the same string given to
        // Swift's `Regex` was not measured, and that engine is the slower one.
        ("(.*)*", "(.*)*"),
        ("x(?:a+){2,}", "(?:a+){2,}"),
        ("(a+?)+", "(a+?)+"),
        ("(?<word>a+)+", "(?<word>a+)+"),
    ])
    func nested(pattern: String, group: String) {
        #expect(RegexStructure.catastrophicGroups(in: pattern)
            == [RegexStructure.Finding(shape: .nestedRepetition, group: group)])
    }

    @Test("overlapping alternation under repetition is found", arguments: [
        ("(a|a)*", "(a|a)*"),
        ("(a|ab)+", "(a|ab)+"),
        (#"(\w|\d)+"#, #"(\w|\d)+"#),
        (#"(.|\s)*"#, #"(.|\s)*"#),
        ("(?:[ab]|[ab])*", "(?:[ab]|[ab])*"),
    ])
    func overlapping(pattern: String, group: String) {
        #expect(RegexStructure.catastrophicGroups(in: pattern)
            == [RegexStructure.Finding(shape: .overlappingAlternation, group: group)])
    }

    @Test("benign shapes are clean", arguments: [
        // SwiftVersionChecker.swift:202, verbatim — the reason for the mandatory-literal clause.
        #"//\s*swift-tools-version:\s*(\d+(?:\.\d+)*)"#,
        #"(\d+,)*\d+"#,
        "(?>a+)+",
        "(a++)+",
        "(ab)+",
        "a+b+",
        "[a-z]+",
        #"\(a+\)+"#,
        "[(a+)+]",
        "(a|b)*",
        #"(\d|x)+"#,
        "(a+)",
        "(a+){2}",
        "(a+)?",
        "(?i)(?:foo|bar)+",
        "(?#(a+)+)x",
        #"\Q(a+)+\E"#,
        "",
    ])
    func clean(pattern: String) {
        #expect(RegexStructure.catastrophicGroups(in: pattern).isEmpty)
    }

    @Test("an interpolation is an opaque atom: neither a literal nor a repetition")
    func opaqueAtom() {
        let hole = String(RegexStructure.opaqueAtom)
        // The hole is not a mandatory literal, so the quantified inner atom still decides…
        #expect(RegexStructure.catastrophicGroups(in: "(\(hole)a+)+").map(\.shape) == [.nestedRepetition])
        // …and an unquantified hole alone is not a repetition.
        #expect(RegexStructure.catastrophicGroups(in: "(\(hole))+").isEmpty)
    }

    @Test("every catastrophic group is reported, nested ones included")
    func several() {
        #expect(RegexStructure.catastrophicGroups(in: "(a+)+|(b|b)*") == [
            RegexStructure.Finding(shape: .nestedRepetition, group: "(a+)+"),
            RegexStructure.Finding(shape: .overlappingAlternation, group: "(b|b)*"),
        ])
    }

    @Test("a malformed pattern is not a finding and does not trap", arguments: ["(a+", "a+)", "[abc", #"\"#, "(?", "{", "a{2,"])
    func malformed(pattern: String) {
        #expect(RegexStructure.catastrophicGroups(in: pattern).isEmpty)
    }

    @Test("§6 limit: overlap behind a separator is not seen")
    func overlapBehindSeparator() {
        // `(a+a)*` is exponential and has a mandatory literal; the clause asks whether a literal
        // is present, not whether the quantified atom can match it.
        #expect(RegexStructure.catastrophicGroups(in: "(a+a)*").isEmpty)
    }
}
