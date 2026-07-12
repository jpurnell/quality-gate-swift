import Foundation
import Testing
import QualityGateCore
@testable import IdiomAuditor

// MARK: - Helpers

/// Audits `source` and returns only the diagnostics for `rule`.
private func findings(
    _ source: String,
    rule: String,
    config: IdiomConfig = IdiomConfig()
) -> [Diagnostic] {
    IdiomAuditor(config: config)
        .auditSource(source, filePath: "fixture.swift")
        .diagnostics
        .filter { $0.ruleId == rule }
}

/// Applies the first suggested fix for `rule` by replacing `original` in `source`,
/// then asserts the fixed source re-parses cleanly and no longer triggers the rule.
private struct RoundTripOutcome {
    let parsesCleanly: Bool
    let remainingFindings: Int
}

private func fixRoundTrip(
    source: String,
    original: String,
    rule: String,
    config: IdiomConfig = IdiomConfig()
) throws -> RoundTripOutcome {
    let auditor = IdiomAuditor(config: config)
    let before = auditor.auditSource(source, filePath: "fixture.swift").diagnostics
    let finding = try #require(before.first { $0.ruleId == rule })
    let fix = try #require(finding.suggestedFix)
    let fixed = source.replacingOccurrences(of: original, with: fix)
    let after = auditor.auditSource(fixed, filePath: "fixture.swift").diagnostics
        .filter { $0.ruleId == rule }
    return RoundTripOutcome(
        parsesCleanly: IdiomAuditor.parsesCleanly(fixed),
        remainingFindings: after.count)
}

// MARK: - AST rules

@Suite("idiom.empty-count")
struct EmptyCountTests {
    @Test("flags .count == 0 with isEmpty fix")
    func flagsEqualsZero() throws {
        let diags = findings("let flag = items.count == 0", rule: "idiom.empty-count")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.lineNumber == 1)
        #expect(d.suggestedFix == "items.isEmpty")
        #expect(d.severity == .note)
    }

    @Test("flags .count != 0 with !isEmpty fix")
    func flagsNotEqualsZero() throws {
        let diags = findings("if items.count != 0 { work() }", rule: "idiom.empty-count")
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "!items.isEmpty")
    }

    @Test("flags .count > 0 with !isEmpty fix")
    func flagsGreaterThanZero() throws {
        let diags = findings("while queue.count > 0 { step() }", rule: "idiom.empty-count")
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "!queue.isEmpty")
    }

    @Test("does not flag a plain identifier named count")
    func plainIdentifier() {
        let source = """
        let count = 0
        let equal = count == 0
        """
        #expect(findings(source, rule: "idiom.empty-count").count == 0)
    }

    @Test("does not flag count comparisons inside strings or comments")
    func stringsAndComments() {
        let source = """
        // items.count == 0 is discouraged
        let s = "items.count == 0"
        """
        #expect(findings(source, rule: "idiom.empty-count").count == 0)
    }

    @Test("fix round-trips")
    func roundTrip() throws {
        let outcome = try fixRoundTrip(
            source: "let flag = items.count == 0",
            original: "items.count == 0",
            rule: "idiom.empty-count"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }
}

@Suite("idiom.redundant-optional-init")
struct RedundantOptionalInitTests {
    @Test("flags var x: T? = nil")
    func flagsVarNil() throws {
        let diags = findings("var name: String? = nil", rule: "idiom.redundant-optional-init")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "var name: String?")
    }

    @Test("does not flag let x: T? = nil")
    func letIsExempt() {
        #expect(findings("let name: String? = nil", rule: "idiom.redundant-optional-init").count == 0)
    }

    @Test("does not flag var without nil initializer")
    func noInitializer() {
        let source = """
        var name: String?
        var other: String? = "seed"
        """
        #expect(findings(source, rule: "idiom.redundant-optional-init").count == 0)
    }

    @Test("fix round-trips")
    func roundTrip() throws {
        let outcome = try fixRoundTrip(
            source: "var name: String? = nil",
            original: "var name: String? = nil",
            rule: "idiom.redundant-optional-init"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }
}

@Suite("idiom.redundant-nil-coalescing")
struct RedundantNilCoalescingTests {
    @Test("flags expr ?? nil")
    func flagsNilRHS() throws {
        let diags = findings("let y = maybe ?? nil", rule: "idiom.redundant-nil-coalescing")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "maybe")
    }

    @Test("does not flag expr ?? fallback")
    func realFallback() {
        #expect(findings("let y = maybe ?? 0", rule: "idiom.redundant-nil-coalescing").count == 0)
    }

    @Test("fix round-trips")
    func roundTrip() throws {
        let outcome = try fixRoundTrip(
            source: "let y = maybe ?? nil",
            original: "maybe ?? nil",
            rule: "idiom.redundant-nil-coalescing"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }
}

@Suite("idiom.redundant-discardable-let")
struct RedundantDiscardableLetTests {
    @Test("flags let _ = expr")
    func flagsLetUnderscore() throws {
        let diags = findings("let _ = compute()", rule: "idiom.redundant-discardable-let")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "_ = compute()")
    }

    @Test("does not flag _ = expr or named let")
    func mustNotFlag() {
        let source = """
        _ = compute()
        let value = compute()
        """
        #expect(findings(source, rule: "idiom.redundant-discardable-let").count == 0)
    }

    @Test("fix round-trips")
    func roundTrip() throws {
        let outcome = try fixRoundTrip(
            source: "let _ = compute()",
            original: "let _ = compute()",
            rule: "idiom.redundant-discardable-let"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }
}

@Suite("idiom.syntactic-sugar")
struct SyntacticSugarTests {
    @Test("flags Array<Int> in a type position")
    func flagsArray() throws {
        let diags = findings("let a: Array<Int> = [1]", rule: "idiom.syntactic-sugar")
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "[Int]")
    }

    @Test("flags Dictionary<String, Int> in a type position")
    func flagsDictionary() throws {
        let diags = findings("let d: Dictionary<String, Int> = [:]", rule: "idiom.syntactic-sugar")
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "[String: Int]")
    }

    @Test("flags Optional<Int> in a type position")
    func flagsOptional() throws {
        let diags = findings("let o: Optional<Int> = nil", rule: "idiom.syntactic-sugar")
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "Int?")
    }

    @Test("does not flag other generic types")
    func otherGenerics() {
        let source = """
        let s: Set<Int> = []
        var r: Result<Int, Error>?
        """
        #expect(findings(source, rule: "idiom.syntactic-sugar").count == 0)
    }

    @Test("Array fix round-trips")
    func roundTripArray() throws {
        let outcome = try fixRoundTrip(
            source: "let a: Array<Int> = [1]",
            original: "Array<Int>",
            rule: "idiom.syntactic-sugar"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }

    @Test("Dictionary fix round-trips")
    func roundTripDictionary() throws {
        let outcome = try fixRoundTrip(
            source: "let d: Dictionary<String, Int> = [:]",
            original: "Dictionary<String, Int>",
            rule: "idiom.syntactic-sugar"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }
}

@Suite("idiom.shorthand-operator")
struct ShorthandOperatorTests {
    private func body(_ statement: String) -> String {
        """
        func f() {
            var x = 1
            \(statement)
        }
        """
    }

    @Test("flags x = x op e", arguments: [
        ("x = x + 1", "x += 1"),
        ("x = x - 1", "x -= 1"),
        ("x = x * 2", "x *= 2"),
        ("x = x / 2", "x /= 2"),
    ])
    func flagsSameLvalue(statement: String, expectedFix: String) throws {
        let diags = findings(body(statement), rule: "idiom.shorthand-operator")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.suggestedFix == expectedFix)
        #expect(d.lineNumber == 3)
    }

    @Test("does not flag different lvalue or existing compound assignment")
    func mustNotFlag() {
        let source = """
        func f() {
            var x = 1
            let y = 2
            x = y + 1
            x += 1
        }
        """
        #expect(findings(source, rule: "idiom.shorthand-operator").count == 0)
    }

    @Test("stays conservative on multi-operand right-hand sides")
    func multiOperandRHS() {
        #expect(findings(body("x = x + 1 + 2"), rule: "idiom.shorthand-operator").count == 0)
    }

    @Test("fix round-trips")
    func roundTrip() throws {
        let outcome = try fixRoundTrip(
            source: body("x = x + 2"),
            original: "x = x + 2",
            rule: "idiom.shorthand-operator"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }
}

@Suite("idiom.identifier-name")
struct IdentifierNameTests {
    @Test("flags an uppercase-start variable name")
    func flagsUppercaseVariable() throws {
        let diags = findings("let Number = 5", rule: "idiom.identifier-name")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.lineNumber == 1)
    }

    @Test("flags a too-short non-allowlisted name")
    func flagsShortName() {
        #expect(findings("let a = 1", rule: "idiom.identifier-name").count == 1)
    }

    @Test("flags an uppercase-start function name")
    func flagsUppercaseFunction() {
        #expect(findings("func Process() {}", rule: "idiom.identifier-name").count == 1)
    }

    @Test("does not flag allowlisted short names or underscore prefixes")
    func allowlistAndUnderscore() {
        let source = """
        let i = 0
        let id = 3
        let dx = 0.5
        let _tmp = 1
        """
        #expect(findings(source, rule: "idiom.identifier-name").count == 0)
    }

    @Test("does not flag operator functions")
    func operatorFunctions() {
        let source = """
        struct Point: Equatable {
            static func == (lhs: Point, rhs: Point) -> Bool { true }
        }
        """
        #expect(findings(source, rule: "idiom.identifier-name").count == 0)
    }

    @Test("does not flag backtick-escaped enum cases")
    func backtickEnumCases() {
        let source = """
        enum Keyword {
            case `default`
            case `is`
        }
        """
        let config = IdiomConfig(minIdentifierLength: 3)
        #expect(findings(source, rule: "idiom.identifier-name", config: config).count == 0)
    }

    @Test("custom allowlist is honored")
    func customAllowlist() {
        let config = IdiomConfig(allowedShortIdentifiers: ["q"])
        #expect(findings("let q = 1", rule: "idiom.identifier-name", config: config).count == 0)
        #expect(findings("let w = 1", rule: "idiom.identifier-name", config: config).count == 1)
    }
}

@Suite("idiom.type-name")
struct TypeNameTests {
    @Test("flags a lowercase-start type name")
    func flagsLowercase() {
        #expect(findings("struct myType {}", rule: "idiom.type-name").count == 1)
    }

    @Test("flags a type name over the maximum length")
    func flagsOverlong() {
        let name = "T" + String(repeating: "o", count: 52)
        #expect(findings("struct \(name) {}", rule: "idiom.type-name").count == 1)
    }

    @Test("flags snake_case type names")
    func flagsSnakeCase() {
        #expect(findings("enum http_status {}", rule: "idiom.type-name").count >= 1)
    }

    @Test("does not flag UpperCamelCase or underscore-prefixed types")
    func mustNotFlag() {
        let source = """
        struct MyType {}
        class _Internal {}
        protocol Runner {}
        actor Pool {}
        typealias Alias = Int
        """
        #expect(findings(source, rule: "idiom.type-name").count == 0)
    }
}

@Suite("idiom.todo-policy")
struct TodoPolicyTests {
    @Test("flags a TODO without a ticket reference")
    func flagsBareTodo() throws {
        let source = """
        // TODO: fix this later
        let x = 1
        """
        let diags = findings(source, rule: "idiom.todo-policy")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.lineNumber == 1)
    }

    @Test("flags a FIXME without a ticket reference")
    func flagsBareFixme() {
        let source = """
        let x = 1 // FIXME: crashes sometimes
        """
        #expect(findings(source, rule: "idiom.todo-policy").count == 1)
    }

    @Test("does not flag TODOs carrying a ticket")
    func ticketedTodos() {
        let source = """
        // TODO: JIRA-123 fix this properly
        // FIXME: see #42 for the crash log
        let x = 1
        """
        #expect(findings(source, rule: "idiom.todo-policy").count == 0)
    }

    @Test("does not flag TODO inside a string literal")
    func stringLiteral() {
        #expect(findings(#"let s = "TODO: not a comment""#, rule: "idiom.todo-policy").count == 0)
    }

    @Test("custom ticket pattern is honored")
    func customPattern() {
        let config = IdiomConfig(todoTicketPattern: "QG-[0-9]+")
        let source = """
        // TODO: QG-7 wire the orchestrator
        let x = 1
        """
        #expect(findings(source, rule: "idiom.todo-policy", config: config).count == 0)
        let bare = """
        // TODO: JIRA-123 no longer counts
        let x = 1
        """
        #expect(findings(bare, rule: "idiom.todo-policy", config: config).count == 1)
    }
}

@Suite("idiom.file-length")
struct FileLengthTests {
    @Test("flags a file over the configured maximum")
    func flagsLongFile() {
        let config = IdiomConfig(maxFileLength: 5)
        let source = (1...7).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
        #expect(findings(source, rule: "idiom.file-length", config: config).count == 1)
    }

    @Test("does not flag a file at the maximum")
    func atLimit() {
        let config = IdiomConfig(maxFileLength: 5)
        let source = (1...5).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
        #expect(findings(source, rule: "idiom.file-length", config: config).count == 0)
    }
}

@Suite("idiom.function-body-length")
struct FunctionBodyLengthTests {
    @Test("flags a body over the configured maximum")
    func flagsLongBody() throws {
        let config = IdiomConfig(maxFunctionBodyLength: 3)
        let source = """
        func long() {
            let v1 = 1
            let v2 = 2
            let v3 = 3
            let v4 = 4
        }
        """
        let diags = findings(source, rule: "idiom.function-body-length", config: config)
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.lineNumber == 1)
    }

    @Test("does not flag a body at the maximum")
    func atLimit() {
        let config = IdiomConfig(maxFunctionBodyLength: 3)
        let source = """
        func short() {
            let v1 = 1
            let v2 = 2
            let v3 = 3
        }
        """
        #expect(findings(source, rule: "idiom.function-body-length", config: config).count == 0)
    }
}

@Suite("idiom.line-length")
struct LineLengthTests {
    @Test("flags a line over the configured maximum")
    func flagsLongLine() throws {
        let config = IdiomConfig(maxLineLength: 40)
        let source = "let veryLongVariableName = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\nlet ok = 1"
        let diags = findings(source, rule: "idiom.line-length", config: config)
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.lineNumber == 1)
    }

    @Test("exempts URL-only lines")
    func urlOnlyLines() {
        let config = IdiomConfig(maxLineLength: 40)
        let source = "// https://example.com/a/very/long/path/that/exceeds/the/limit/easily\nlet ok = 1"
        #expect(findings(source, rule: "idiom.line-length", config: config).count == 0)
    }
}

@Suite("idiom.trailing-whitespace")
struct TrailingWhitespaceTests {
    @Test("flags trailing spaces with a trimmed fix")
    func flagsTrailingSpaces() throws {
        let source = "let x = 1   \nlet y = 2"
        let diags = findings(source, rule: "idiom.trailing-whitespace")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.lineNumber == 1)
        #expect(d.suggestedFix == "let x = 1")
    }

    @Test("flags trailing tabs")
    func flagsTrailingTabs() {
        #expect(findings("let x = 1\t", rule: "idiom.trailing-whitespace").count == 1)
    }

    @Test("does not flag clean lines")
    func cleanLines() {
        #expect(findings("let x = 1\nlet y = 2", rule: "idiom.trailing-whitespace").count == 0)
    }

    @Test("fix round-trips")
    func roundTrip() throws {
        let outcome = try fixRoundTrip(
            source: "let x = 1   \nlet y = 2",
            original: "let x = 1   ",
            rule: "idiom.trailing-whitespace"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }
}

@Suite("idiom.trailing-newline")
struct TrailingNewlineTests {
    @Test("flags a missing trailing newline")
    func missingNewline() throws {
        let diags = findings("let x = 1", rule: "idiom.trailing-newline")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "\n")
    }

    @Test("flags multiple trailing newlines")
    func multipleNewlines() {
        #expect(findings("let x = 1\n\n", rule: "idiom.trailing-newline").count == 1)
    }

    @Test("does not flag exactly one trailing newline")
    func exactlyOne() {
        #expect(findings("let x = 1\n", rule: "idiom.trailing-newline").count == 0)
    }
}

@Suite("idiom.vertical-whitespace")
struct VerticalWhitespaceTests {
    @Test("flags more than the configured consecutive blank lines")
    func flagsExcessBlanks() throws {
        let source = "let a = 1\n\n\n\nlet b = 2\n"
        let diags = findings(source, rule: "idiom.vertical-whitespace")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.lineNumber == 4)
    }

    @Test("does not flag blank runs at the limit")
    func atLimit() {
        let source = "let a = 1\n\n\nlet b = 2\n"
        #expect(findings(source, rule: "idiom.vertical-whitespace").count == 0)
    }

    @Test("custom limit is honored")
    func customLimit() {
        let config = IdiomConfig(maxConsecutiveBlankLines: 1)
        let source = "let a = 1\n\n\nlet b = 2\n"
        #expect(findings(source, rule: "idiom.vertical-whitespace", config: config).count == 1)
    }
}

@Suite("idiom.unused-closure-parameter")
struct UnusedClosureParameterTests {
    @Test("flags a named closure parameter that is never referenced")
    func flagsUnused() throws {
        let diags = findings("let r = [1].map { value in 7 }", rule: "idiom.unused-closure-parameter")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "_")
    }

    @Test("does not flag used parameters, underscores, or shorthand closures")
    func mustNotFlag() {
        let source = """
        let a = [1].map { value in value + 1 }
        let b = [1].map { _ in 7 }
        let c = [1].map { $0 + 1 }
        """
        #expect(findings(source, rule: "idiom.unused-closure-parameter").count == 0)
    }

    @Test("flags unused parameters declared with a parameter clause")
    func parameterClauseForm() {
        let source = "let r = [1].map { (value: Int) -> Int in 7 }"
        #expect(findings(source, rule: "idiom.unused-closure-parameter").count == 1)
    }

    @Test("fix round-trips")
    func roundTrip() throws {
        let outcome = try fixRoundTrip(
            source: "let r = [1].map { value in 7 }",
            original: "value",
            rule: "idiom.unused-closure-parameter"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }
}

@Suite("idiom.implicit-getter")
struct ImplicitGetterTests {
    @Test("flags a computed property with a lone get block")
    func flagsLoneGet() throws {
        let source = """
        struct Box {
            var value: Int { get { 1 } }
        }
        """
        let diags = findings(source, rule: "idiom.implicit-getter")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "1")
    }

    @Test("does not flag implicit getters, get+set, effectful getters, or protocol requirements")
    func mustNotFlag() {
        let source = """
        struct Box {
            var stored: Int = 0
            var a: Int { 1 }
            var b: Int {
                get { stored }
                set { stored = newValue }
            }
            var c: Int { get async { 1 } }
        }
        protocol Readable {
            var value: Int { get }
        }
        """
        #expect(findings(source, rule: "idiom.implicit-getter").count == 0)
    }

    @Test("fix round-trips")
    func roundTrip() throws {
        let outcome = try fixRoundTrip(
            source: """
            struct Box {
                var value: Int { get { 1 } }
            }
            """,
            original: "get { 1 }",
            rule: "idiom.implicit-getter"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }
}

@Suite("idiom.redundant-string-enum-value")
struct RedundantStringEnumValueTests {
    @Test("flags a raw value equal to the case name")
    func flagsRedundantValue() throws {
        let source = #"enum Fruit: String { case apple = "apple" }"#
        let diags = findings(source, rule: "idiom.redundant-string-enum-value")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "case apple")
    }

    @Test("does not flag differing raw values, non-String enums, or plain cases")
    func mustNotFlag() {
        let source = #"""
        enum Fruit: String {
            case apple = "Apple"
            case pear
        }
        enum Rank: Int { case one = 1 }
        enum Plain { case solo }
        """#
        #expect(findings(source, rule: "idiom.redundant-string-enum-value").count == 0)
    }

    @Test("fix round-trips")
    func roundTrip() throws {
        let outcome = try fixRoundTrip(
            source: #"enum Fruit: String { case apple = "apple" }"#,
            original: #"case apple = "apple""#,
            rule: "idiom.redundant-string-enum-value"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }
}

@Suite("idiom.legacy-random")
struct LegacyRandomTests {
    @Test("flags legacy C random APIs", arguments: [
        "let r = arc4random()",
        "let r = arc4random_uniform(10)",
        "let r = drand48()",
    ])
    func flagsLegacyCalls(source: String) {
        #expect(findings(source, rule: "idiom.legacy-random").count == 1)
    }

    @Test("does not flag Swift random APIs or similarly named helpers")
    func mustNotFlag() {
        let source = """
        let a = Int.random(in: 0..<10)
        let b = arc4randomish()
        """
        #expect(findings(source, rule: "idiom.legacy-random").count == 0)
    }
}

@Suite("idiom.contains-over-first")
struct ContainsOverFirstTests {
    @Test("flags first(where:) != nil with contains fix")
    func flagsNotNil() throws {
        let source = "let has = list.first(where: { $0 > 1 }) != nil"
        let diags = findings(source, rule: "idiom.contains-over-first")
        #expect(diags.count == 1)
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "list.contains(where: { $0 > 1 })")
    }

    @Test("flags first(where:) == nil with negated contains fix")
    func flagsIsNil() throws {
        let source = "let missing = list.first(where: { $0 > 1 }) == nil"
        let diags = findings(source, rule: "idiom.contains-over-first")
        let d = try #require(diags.first)
        #expect(d.suggestedFix == "!list.contains(where: { $0 > 1 })")
    }

    @Test("does not flag bare first(where:) or plain first comparisons")
    func mustNotFlag() {
        let source = """
        let f = list.first(where: { $0 > 1 })
        let g = list.first
        """
        #expect(findings(source, rule: "idiom.contains-over-first").count == 0)
    }

    @Test("fix round-trips")
    func roundTrip() throws {
        let outcome = try fixRoundTrip(
            source: "let has = list.first(where: { $0 > 1 }) != nil",
            original: "list.first(where: { $0 > 1 }) != nil",
            rule: "idiom.contains-over-first"
        )
        #expect(outcome.parsesCleanly)
        #expect(outcome.remainingFindings == 0)
    }
}

// MARK: - Exemptions, severity, config

@Suite("idiom exemptions and severity")
struct ExemptionAndSeverityTests {
    @Test("// idiom:exempt suppresses the finding and records an override")
    func exemptRecordsOverride() throws {
        let source = "let flag = items.count == 0 // idiom:exempt\n"
        let audit = IdiomAuditor().auditSource(source, filePath: "fixture.swift")
        #expect(audit.diagnostics.count == 0)
        #expect(audit.overrides.count == 1)
        let override = try #require(audit.overrides.first)
        #expect(override.ruleId == "idiom.empty-count")
        #expect(override.justification == "// idiom:exempt")
        #expect(override.filePath == "fixture.swift")
        #expect(override.lineNumber == 1)
    }

    @Test("exemption only covers its own line")
    func exemptionIsLineScoped() {
        let source = """
        let flag = items.count == 0 // idiom:exempt
        let other = items.count != 0
        """ + "\n"
        let audit = IdiomAuditor().auditSource(source, filePath: "fixture.swift")
        #expect(audit.diagnostics.count == 1)
        #expect(audit.overrides.count == 1)
    }

    @Test("findings are .note by default and .warning when escalated")
    func severityKnob() throws {
        let source = "let flag = items.count == 0"
        let note = try #require(
            IdiomAuditor().auditSource(source, filePath: "f.swift").diagnostics.first
        )
        #expect(note.severity == .note)
        let escalated = try #require(
            IdiomAuditor(config: IdiomConfig(escalateToWarning: true))
                .auditSource(source, filePath: "f.swift").diagnostics.first
        )
        #expect(escalated.severity == .warning)
    }
}

@Suite("IdiomConfig decoding")
struct IdiomConfigDecodingTests {
    @Test("an empty document decodes to all defaults")
    func emptyDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(IdiomConfig.self, from: Data("{}".utf8))
        #expect(decoded == IdiomConfig())
    }

    @Test("defaults have the documented values")
    func documentedDefaults() {
        let config = IdiomConfig()
        #expect(config.escalateToWarning == false)
        #expect(config.minIdentifierLength == 2)
        #expect(config.allowedShortIdentifiers == ["i", "j", "k", "x", "y", "z", "id", "to", "at", "in", "dx", "dy"])
        #expect(config.todoTicketPattern == "[A-Z]+-[0-9]+|#[0-9]+")
        #expect(config.maxFileLength == 1000)
        #expect(config.maxFunctionBodyLength == 100)
        #expect(config.maxLineLength == 200)
        #expect(config.maxConsecutiveBlankLines == 2)
        #expect(config.maxTypeNameLength == 50)
    }

    @Test("partial documents override only the present keys")
    func partialOverride() throws {
        let decoded = try JSONDecoder().decode(
            IdiomConfig.self,
            from: Data(#"{"maxLineLength": 120, "escalateToWarning": true}"#.utf8)
        )
        #expect(decoded.maxLineLength == 120)
        #expect(decoded.escalateToWarning == true)
        #expect(decoded.minIdentifierLength == 2)
        #expect(decoded.maxFileLength == 1000)
    }
}

// MARK: - End-to-end through check(configuration:)

@Suite("IdiomAuditor.check end-to-end", .serialized)
struct IdiomAuditorEndToEndTests {
    private func makeFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdiomAuditorE2E-\(UUID().uuidString)")
        let sourcesDir = root.appendingPathComponent("Sources/ModA")
        let testsDir = root.appendingPathComponent("Tests/ModATests")
        let ignoredDir = root.appendingPathComponent("Other")
        for dir in [sourcesDir, testsDir, ignoredDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "let flag = [1].count == 0\n".write(
            to: sourcesDir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "let _ = 5\n".write(
            to: testsDir.appendingPathComponent("T.swift"), atomically: true, encoding: .utf8)
        try "let _ = 9\n".write(
            to: ignoredDir.appendingPathComponent("O.swift"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("walks Sources and Tests, always passes, and is deterministic")
    func endToEnd() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort temp cleanup
        let auditor = IdiomAuditor(root: root.path)
        let result = try await auditor.check(configuration: Configuration())
        #expect(result.checkerId == "idiom")
        #expect(result.status == .passed)
        #expect(result.diagnostics.count == 2)
        let rules = result.diagnostics.compactMap { $0.ruleId }
        #expect(rules == ["idiom.empty-count", "idiom.redundant-discardable-let"])
        let paths = result.diagnostics.compactMap { $0.filePath }
        #expect(paths == paths.sorted())
        #expect(paths.allSatisfy { !$0.contains("/Other/") })
        for d in result.diagnostics {
            #expect(d.severity == .note)
        }
        let rerun = try await auditor.check(configuration: Configuration())
        #expect(rerun.diagnostics == result.diagnostics)
    }

    @Test("status stays .passed even when findings are escalated to warnings")
    func escalatedStillPasses() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort temp cleanup
        let auditor = IdiomAuditor(config: IdiomConfig(escalateToWarning: true), root: root.path)
        let result = try await auditor.check(configuration: Configuration())
        #expect(result.status == .passed)
        #expect(result.diagnostics.count == 2)
        for d in result.diagnostics {
            #expect(d.severity == .warning)
        }
    }
}
