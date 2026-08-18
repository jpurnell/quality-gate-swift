import Testing
@testable import TestQualityAuditor

@Suite("PropertyCoverage")
struct PropertyCoverageTests {

    private func candidates(_ source: String) -> [PropertyCoverage.Candidate] {
        PropertyCoverage.candidates(in: source, path: "F.swift").candidates
    }

    // MARK: - Shape classification

    @Test("A parser taking text is a parser")
    func parserIsClassified() {
        let found = candidates("func parseManifest(from source: String) -> [String] { [] }")
        #expect(found.first?.shape == .parser)
    }

    /// Name alone is not enough. `parse` over an already-structured value has no
    /// large input space and no invariant this rule can name.
    @Test("A parse-named function that takes no text is not a parser")
    func parserRequiresText() {
        #expect(candidates("func parseAll(from values: [Int]) -> [String] { [] }").isEmpty)
    }

    @Test("Comparators, orderings and normalisers are classified")
    func otherShapes() {
        #expect(candidates("func matchesPattern(_ a: Int, _ b: Int) -> Bool { true }")
            .first?.shape == .comparator)
        #expect(candidates("func sortRules(_ r: [Int]) -> [Int] { r }")
            .first?.shape == .ordering)
        #expect(candidates("func normalise(_ text: String) -> String { text }")
            .first?.shape == .normaliser)
    }

    /// Balance is checked before comparator: `matchingParen` contains "match" but is a
    /// bracket matcher, and the invariant it owes is the balance one.
    @Test("A bracket matcher is balance, not comparator")
    func balanceBeatsComparator() {
        #expect(candidates("func matchingParen(in t: String, at i: Int) -> Int? { nil }")
            .first?.shape == .balance)
    }

    // MARK: - The pairing rule

    /// **A renderer with no parser in its file is never a candidate.** Requiring a
    /// property of `emitDiagnostics` requires a tautology.
    @Test("A renderer in a file that does not parse is not a candidate")
    func lonelyRendererIsNotACandidate() {
        #expect(candidates("func emitDiagnostics(_ d: [String]) { }").isEmpty)
    }

    /// Module scope was tried first and let `formatDuration` through because some
    /// other file in the module parsed. The pairing is file-scoped.
    @Test("A renderer becomes a candidate only when its own file parses")
    func rendererPairsWithinItsFile() {
        let paired = """
            func parseThing(from text: String) -> Int { 0 }
            func renderThing(_ value: Int) -> String { "" }
            """
        let shapes = candidates(paired).map(\.shape)
        #expect(shapes.contains(.parser))
        #expect(shapes.contains(.roundTrip))
    }

    // MARK: - Nested functions

    /// A local function inside another function's body is not API and cannot be
    /// property-tested from outside. `canonicalize` declared inside an index pass is
    /// the shape that surfaced this.
    @Test("A nested local function is not a candidate")
    func nestedFunctionIsNotACandidate() {
        let source = """
            func outer(_ paths: [String]) -> [String] {
                func canonicalize(_ path: String) -> String { path }
                return paths.map(canonicalize)
            }
            """
        #expect(!candidates(source).contains { $0.name == "canonicalize" })
    }

    // MARK: - Property-shaped test detection

    @Test("Seeded, looping, arguments and round-trip tests all count as properties")
    func propertyShapesAreRecognised() {
        #expect(PropertyCoverage.isPropertyShaped(
            attribute: "(arguments: [1, 2])", body: "parseThing(x)"))
        #expect(PropertyCoverage.isPropertyShaped(
            attribute: "", body: "var rng = Seeded(seed: 1); parseThing(x)"))
        #expect(PropertyCoverage.isPropertyShaped(
            attribute: "", body: "for i in 0..<50 { parseThing(i) }"))
        #expect(PropertyCoverage.isPropertyShaped(
            attribute: "", body: "#expect(parse(render(x)) == x)"))
    }

    /// **The counter-example that must stay silent.** A regression test pinned to a
    /// real artefact has no property, and reporting the function it names would tell
    /// the author to destroy the thing that makes the test worth having.
    @Test("An example test is not mistaken for a property")
    func exampleIsNotAProperty() {
        #expect(!PropertyCoverage.isPropertyShaped(
            attribute: "", body: #"#expect(diagnose(tiledKernel).isEmpty)"#))
    }

    /// Fixture strings in a linter's own tests contain `@Test`; counting them inflated
    /// this package's test count from 2,968 to 3,068 against a known 2,993.
    @Test("A @Test inside a string fixture is not a test")
    func fixturesAreNotTests() {
        let source = #"""
            @Test("real") func real() { var rng = Seeded(seed: 1); parseReal(rng) }
            let fixture = """
                @Test("fake") func fake() { for i in 0..<9 { parseFake(i) } }
                """
            """#
        let covered = PropertyCoverage.propertyCoveredSymbols(inTestSource: source)
        #expect(covered.contains("parseReal"))
        #expect(!covered.contains("parseFake"))
    }

    // MARK: - Findings and delegation

    private let parserCandidate = PropertyCoverage.Candidate(
        name: "matching", shape: .balance, path: "F.swift", line: 10)

    @Test("An uncovered candidate produces a warning naming its invariant")
    func uncoveredProducesFinding() {
        let findings = PropertyCoverage.findings(
            candidates: [parserCandidate], calls: [:], coveredDirectly: [])
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.ruleId == "test-quality.property-coverage")
        #expect(findings.first?.message.contains("closes the opener") == true)
    }

    @Test("A directly covered candidate produces nothing")
    func directlyCoveredIsSilent() {
        #expect(PropertyCoverage.findings(
            candidates: [parserCandidate], calls: [:],
            coveredDirectly: ["matching"]).isEmpty)
    }

    /// **One level of delegation counts.** A property on `matchingParen` covers
    /// `matching`, which it delegates to. Not counting this produced 52 false
    /// positives on this package.
    @Test("A candidate reached through one level of delegation is covered")
    func delegationCovers() {
        #expect(PropertyCoverage.findings(
            candidates: [parserCandidate],
            calls: ["matchingParen": ["matching"]],
            coveredDirectly: ["matchingParen"]).isEmpty)
    }

    /// **Two levels do not.** Depth is fixed at one; the count is violently sensitive
    /// to the bound and a configurable depth lets a project tune its way to zero.
    @Test("Two levels of delegation do not count as coverage")
    func delegationDoesNotChain() {
        let findings = PropertyCoverage.findings(
            candidates: [parserCandidate],
            calls: ["outer": ["matchingParen"], "matchingParen": ["matching"]],
            coveredDirectly: ["outer"])
        #expect(findings.count == 1, "coverage leaked through two delegation levels")
    }

    @Test("Findings are ordered by file then line")
    func orderedFindings() {
        let unsorted = [
            PropertyCoverage.Candidate(name: "b", shape: .parser, path: "B.swift", line: 1),
            PropertyCoverage.Candidate(name: "a2", shape: .parser, path: "A.swift", line: 9),
            PropertyCoverage.Candidate(name: "a1", shape: .parser, path: "A.swift", line: 2),
        ]
        // Compared as (path, line) rather than as a zero-padded string key. The padding
        // existed only to make a lexicographic sort agree with a numeric one, which is an
        // assumption about how many digits a line number has; the tuple ordering *is* the
        // ordering under test.
        let keys = PropertyCoverage.findings(
            candidates: unsorted, calls: [:], coveredDirectly: []
        ).map { ($0.filePath ?? "", $0.lineNumber ?? 0) }
        #expect(keys.elementsEqual(keys.sorted(by: <), by: ==))
    }
}
