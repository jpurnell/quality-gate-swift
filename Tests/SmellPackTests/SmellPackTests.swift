import Foundation
import Testing
import QualityGateCore
@testable import SmellPack

/// Phase 4c §4 — the advisory smell-metric suite.
///
/// The contract under test: every metric flags strictly *over* its threshold
/// and stays quiet *at* it, findings are always `.note` and the checker always
/// reports `.passed` (advisory, never gates), messages state the measured
/// value and the threshold, and `// smell:exempt` on the flagged declaration's
/// line is recorded as an override — never silently dropped.
@Suite("SmellPack")
struct SmellPackTests {

    /// Runs all metrics over one inline source fixture.
    private func analyze(
        _ source: String,
        config: SmellConfig = SmellConfig()
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        SmellPack.analyze(source: source, filePath: "/fixtures/Fixture.swift", config: config)
    }

    // MARK: - smell.parameter-count

    @Test("a function at the parameter threshold does not flag")
    func parameterCountAtThreshold() {
        let result = analyze("func f(a: Int, b: Int, c: Int, d: Int, e: Int) {}")
        #expect(result.diagnostics.isEmpty)
        #expect(result.overrides.isEmpty)
    }

    @Test("a function one over the parameter threshold flags with value and threshold")
    func parameterCountOverThreshold() throws {
        let result = analyze("func f(a: Int, b: Int, c: Int, d: Int, e: Int, g: Int) {}")
        #expect(result.diagnostics.count == 1)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.ruleId == "smell.parameter-count")
        #expect(diagnostic.severity == .note)
        #expect(diagnostic.lineNumber == 1)
        #expect(diagnostic.message.contains("6 parameters (threshold 5)"))
    }

    @Test("initializers are measured like functions")
    func initializerParameterCount() throws {
        let result = analyze("struct S { init(a: Int, b: Int, c: Int, d: Int, e: Int, g: Int) {} }")
        #expect(result.diagnostics.count == 1)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.ruleId == "smell.parameter-count")
        #expect(diagnostic.message.contains("6 parameters (threshold 5)"))
    }

    // MARK: - smell.nesting-depth

    @Test("nesting at the depth threshold does not flag")
    func nestingAtThreshold() {
        let result = analyze("func f() { if a { if b { if c { if d { x() } } } } }")
        #expect(result.diagnostics.isEmpty)
    }

    @Test("nesting one past the depth threshold flags at the function")
    func nestingOverThreshold() throws {
        let result = analyze("func f() { if a { if b { if c { if d { if e { x() } } } } } }")
        #expect(result.diagnostics.count == 1)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.ruleId == "smell.nesting-depth")
        #expect(diagnostic.severity == .note)
        #expect(diagnostic.lineNumber == 1)
        #expect(diagnostic.message.contains("depth 5 (threshold 4)"))
    }

    @Test("loops, closures, guards, and switches all deepen nesting")
    func mixedConstructsCount() throws {
        let config = SmellConfig(maxNestingDepth: 2)
        let source = """
        func f(items: [Int]) {
            for item in items {
                items.forEach { value in
                    guard value > 0 else { return }
                    switch value {
                    default:
                        use(value)
                    }
                }
            }
        }
        """
        let result = analyze(source, config: config)
        #expect(result.diagnostics.count == 1)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.ruleId == "smell.nesting-depth")
        #expect(diagnostic.message.contains("depth 3 (threshold 2)"))
    }

    // MARK: - smell.god-object

    @Test("a type at the member-count threshold does not flag")
    func memberCountAtThreshold() {
        let config = SmellConfig(maxTypeMemberCount: 3)
        let source = """
        struct S {
            var a: Int
            var b: Int
            func m() {}
        }
        """
        #expect(analyze(source, config: config).diagnostics.isEmpty)
    }

    @Test("a type one over the member-count threshold flags as a god object")
    func memberCountOverThreshold() throws {
        let config = SmellConfig(maxTypeMemberCount: 3)
        let source = """
        struct S {
            var a: Int
            var b: Int
            var c: Int
            func m() {}
        }
        """
        let result = analyze(source, config: config)
        #expect(result.diagnostics.count == 1)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.ruleId == "smell.god-object")
        #expect(diagnostic.severity == .note)
        #expect(diagnostic.lineNumber == 1)
        #expect(diagnostic.message.contains("4 members (threshold 3)"))
    }

    @Test("same-file extensions count toward the type's members")
    func extensionMembersCount() throws {
        let config = SmellConfig(maxTypeMemberCount: 3)
        let source = """
        struct S {
            var a: Int
            var b: Int
        }
        extension S {
            func m() {}
            func n() {}
        }
        """
        let result = analyze(source, config: config)
        #expect(result.diagnostics.count == 1)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.ruleId == "smell.god-object")
        #expect(diagnostic.lineNumber == 1)
        #expect(diagnostic.message.contains("4 members (threshold 3)"))
    }

    // MARK: - smell.type-length

    @Test("a type body at the length threshold does not flag")
    func typeLengthAtThreshold() {
        let config = SmellConfig(maxTypeBodyLength: 5)
        let vars = (1...3).map { "    var v\($0): Int" }.joined(separator: "\n")
        let source = "struct S {\n\(vars)\n}"
        #expect(analyze(source, config: config).diagnostics.isEmpty)
    }

    @Test("a type body one past the length threshold flags")
    func typeLengthOverThreshold() throws {
        let config = SmellConfig(maxTypeBodyLength: 5)
        let vars = (1...4).map { "    var v\($0): Int" }.joined(separator: "\n")
        let source = "struct S {\n\(vars)\n}"
        let result = analyze(source, config: config)
        #expect(result.diagnostics.count == 1)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.ruleId == "smell.type-length")
        #expect(diagnostic.severity == .note)
        #expect(diagnostic.lineNumber == 1)
        #expect(diagnostic.message.contains("6 lines (threshold 5)"))
    }

    // MARK: - smell.closure-length

    @Test("a closure at the length threshold does not flag")
    func closureLengthAtThreshold() {
        let config = SmellConfig(maxClosureLength: 3)
        let source = "let x = {\n    a()\n}"
        #expect(analyze(source, config: config).diagnostics.isEmpty)
    }

    @Test("a closure one past the length threshold flags")
    func closureLengthOverThreshold() throws {
        let config = SmellConfig(maxClosureLength: 3)
        let source = "let x = {\n    a()\n    b()\n}"
        let result = analyze(source, config: config)
        #expect(result.diagnostics.count == 1)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.ruleId == "smell.closure-length")
        #expect(diagnostic.severity == .note)
        #expect(diagnostic.lineNumber == 1)
        #expect(diagnostic.message.contains("4 lines (threshold 3)"))
    }

    // MARK: - Escape hatch

    @Test("// smell:exempt suppresses the finding and records the override")
    func exemptIsRecordedNotSilent() throws {
        let result = analyze("func f(a: Int, b: Int, c: Int, d: Int, e: Int, g: Int) {} // smell:exempt")
        #expect(result.diagnostics.isEmpty)
        #expect(result.overrides.count == 1)
        let override = try #require(result.overrides.first)
        #expect(override.ruleId == "smell.parameter-count")
        #expect(override.justification == "// smell:exempt")
        #expect(override.filePath == "/fixtures/Fixture.swift")
        #expect(override.lineNumber == 1)
    }

    // MARK: - Config decode

    @Test("an empty document decodes to the default thresholds")
    func configDefaults() throws {
        let decoded = try JSONDecoder().decode(SmellConfig.self, from: Data("{}".utf8))
        #expect(decoded == SmellConfig())
        #expect(decoded.maxParameterCount == 5)
        #expect(decoded.maxNestingDepth == 4)
        #expect(decoded.maxTypeMemberCount == 30)
        #expect(decoded.maxTypeBodyLength == 500)
        #expect(decoded.maxClosureLength == 50)
    }

    @Test("partial config keeps defaults for absent keys and round-trips")
    func configPartialAndRoundTrip() throws {
        let decoded = try JSONDecoder().decode(SmellConfig.self, from: Data(#"{"maxParameterCount":3}"#.utf8))
        #expect(decoded.maxParameterCount == 3)
        #expect(decoded.maxNestingDepth == 4)

        let tuned = SmellConfig(
            maxParameterCount: 2,
            maxNestingDepth: 1,
            maxTypeMemberCount: 7,
            maxTypeBodyLength: 9,
            maxClosureLength: 11)
        let roundTripped = try JSONDecoder().decode(SmellConfig.self, from: JSONEncoder().encode(tuned))
        #expect(roundTripped == tuned)
    }

    // MARK: - End to end

    /// Line layout matters: `wide` is on line 3, `deep` starts on line 5,
    /// and the exempted `allowed` sits on line 19.
    private let smellyFixture = """
    import Foundation

    func wide(a: Int, b: Int, c: Int, d: Int, e: Int, g: Int) -> Int { a }

    func deep() {
        if one {
            if two {
                if three {
                    if four {
                        if five {
                            work()
                        }
                    }
                }
            }
        }
    }

    func allowed(a: Int, b: Int, c: Int, d: Int, e: Int, g: Int) -> Int { a } // smell:exempt
    """

    @Test("end to end: advisory notes, passed status, recorded exemptions")
    func endToEndCheck() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smell-pack-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
        let tests = root.appendingPathComponent("Tests/AppTests", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try smellyFixture.write(
            to: sources.appendingPathComponent("Smelly.swift"), atomically: true, encoding: .utf8)
        try "func wideTest(a: Int, b: Int, c: Int, d: Int, e: Int, g: Int) -> Int { a }\n".write(
            to: tests.appendingPathComponent("WideTests.swift"), atomically: true, encoding: .utf8)

        let checker = SmellPack(root: root.path)
        let result = try await checker.check(configuration: Configuration())

        #expect(result.checkerId == "smells")
        #expect(result.status == .passed)
        #expect(result.diagnostics.allSatisfy { $0.severity == .note })
        let ruleCounts = Dictionary(grouping: result.diagnostics, by: { $0.ruleId ?? "" })
            .mapValues(\.count)
        #expect(ruleCounts == ["smell.parameter-count": 2, "smell.nesting-depth": 1])

        #expect(result.overrides.count == 1)
        let override = try #require(result.overrides.first)
        #expect(override.ruleId == "smell.parameter-count")
        #expect(override.justification == "// smell:exempt")
        #expect(override.lineNumber == 19)
    }
}
