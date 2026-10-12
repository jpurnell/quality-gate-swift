import Foundation
import Testing
@testable import SafetyAuditor
@testable import QualityGateCore

/// A pattern is a program.
///
/// A regular expression is a program for a backtracking interpreter: `(a+)+$` takes 27 s on an
/// eighteen-character subject in Swift `Regex`. These rules report a literal pattern with that
/// shape, a pattern that arrives from outside the program, and an `NSPredicate` /
/// `NSExpression` format string assembled at runtime.
///
/// See `quality-gate-swift-project/plans/proposals/APatternIsAProgram.md` §5; test numbers in
/// the names are that section's. Where this differs from the proposal it is because
/// `regex-from-input` reads the shared external-input model rather than "not a literal" — see
/// the report in the PR.
@Suite("Pattern rules")
struct PatternRulesTests {

    static let catastrophic = "security.regex-catastrophic"
    static let fromInput = "security.regex-from-input"
    static let predicate = "security.predicate-injection"

    private func audit(_ code: String) async throws -> CheckResult {
        try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: Configuration())
    }

    private func findings(_ code: String, _ rule: String) async throws -> [Diagnostic] {
        try await audit(code).diagnostics.filter { $0.ruleId == rule }
    }

    /// `body` inside a function with a plain parameter of each useful kind.
    private func inFunction(_ body: String) -> String {
        """
        import Foundation
        func f(text: String, userPattern: String, rule: Rule) throws {
        \(body)
        }
        """
    }

    // MARK: - Catastrophic literals — error

    @Test("1–4, 6–8. a catastrophic literal at a pattern site is an error", arguments: [
        #"_ = try NSRegularExpression(pattern: "(a+)+$")"#,
        #"_ = try Regex("(a+)+$")"#,
        #"_ = text.range(of: "(\\w+\\s?)*$", options: .regularExpression)"#,
        "_ = text.firstMatch(of: /(a+)+$/)",
        #"_ = try NSRegularExpression(pattern: "(a|a)*")"#,
        #"_ = try NSRegularExpression(pattern: "(a|ab)+")"#,
        #"_ = try NSRegularExpression(pattern: "(\\w|\\d)+")"#,
        #"_ = try NSRegularExpression(pattern: "([a-z]+)*")"#,
        // 8. Measured harmless on ICU at n ≤ 22; flagged because Swift `Regex` was not measured.
        #"_ = try NSRegularExpression(pattern: "(.*)*")"#,
        ##"_ = text.replacingOccurrences(of: #"(\s*\w+)*"#, with: "", options: .regularExpression)"##,
    ])
    func catastrophicLiteral(line: String) async throws {
        let found = try await findings(inFunction(line), Self.catastrophic)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.lineNumber == 3)
        #expect(found.first?.message.contains("[CWE-1333]") == true)
    }

    @Test("5. a file-scope constant is followed to its literal and reported there, once")
    func constantReportedAtLiteral() async throws {
        let code = """
            import Foundation
            let wordRun = #"(\\s*\\w+)*"#
            func f() throws {
                _ = try NSRegularExpression(pattern: wordRun)
                _ = try NSRegularExpression(pattern: wordRun, options: [.caseInsensitive])
            }
            """
        let found = try await findings(code, Self.catastrophic)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 2)
    }

    @Test("the message names the group and the shape")
    func messageNamesGroup() async throws {
        let found = try await findings(inFunction(#"_ = try Regex("^(\\w+\\s?)*$")"#), Self.catastrophic)
        let message = try #require(found.first?.message)
        #expect(message.contains(#""(\\w+\\s?)*""#))
        #expect(message.contains("no separator"))
    }

    // MARK: - Not catastrophic — clean

    @Test("9–17. benign or non-pattern sites are clean", arguments: [
        // 9. SwiftVersionChecker.swift:202, verbatim.
        ##"_ = try NSRegularExpression(pattern: #"//\s*swift-tools-version:\s*(\d+(?:\.\d+)*)"#)"##,
        #"_ = try NSRegularExpression(pattern: "(\\d+,)*\\d+")"#,
        #"_ = try NSRegularExpression(pattern: "(?>a+)+")"#,
        #"_ = try NSRegularExpression(pattern: "(a++)+")"#,
        #"_ = try NSRegularExpression(pattern: "(ab)+")"#,
        #"_ = try NSRegularExpression(pattern: "a+b+")"#,
        #"_ = try NSRegularExpression(pattern: "[a-z]+")"#,
        // 15. not a pattern site
        #"print("(a+)+")"#,
        #"_ = try NSRegularExpression(pattern: "\\(a+\\)+")"#,
        #"_ = try NSRegularExpression(pattern: "[(a+)+]")"#,
        // `of:` without `.regularExpression` is a plain substring search
        #"_ = text.range(of: "(a+)+")"#,
    ])
    func clean(line: String) async throws {
        #expect(try await findings(inFunction(line), Self.catastrophic).isEmpty)
    }

    // MARK: - From input — warning

    @Test("18. a pattern from an MCP tool argument is a warning naming the source and the path")
    func fromMCPArgument() async throws {
        let code = """
            import Foundation
            func execute(arguments: [String: AnyCodable]?) throws {
                guard let args = arguments else { return }
                let raw = try args.getString("pattern")
                let pattern = raw
                _ = try NSRegularExpression(pattern: pattern)
            }
            """
        let found = try await findings(code, Self.fromInput)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.lineNumber == 6)
        #expect(found.first?.message.contains("an MCP tool argument (getString, via raw → pattern)") == true)
        #expect(found.first?.message.contains("[CWE-1333]") == true)
    }

    @Test("19. a command-line option compiled as a Regex is a warning")
    func fromOption() async throws {
        let code = """
            import ArgumentParser
            struct Grep: ParsableCommand {
                @Option var pattern: String
                func run() throws { _ = try Regex(pattern) }
            }
            """
        let found = try await findings(code, Self.fromInput)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("the command line") == true)
    }

    @Test("20. an interpolated environment value is a warning")
    func interpolatedEnvironment() async throws {
        let found = try await findings(inFunction("""
            let prefix = ProcessInfo.processInfo.environment["PREFIX"] ?? ""
            _ = try NSRegularExpression(pattern: "^\\(prefix)\\\\d+")
            """), Self.fromInput)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("the environment") == true)
    }

    @Test("21–22. an escaped interpolation is clean, inline or bound first")
    func escaped() async throws {
        let mcp = """
            import Foundation
            func execute(arguments: [String: AnyCodable]?) throws {
                let marker = arguments?["marker"]?.stringValue ?? ""
                %@
            }
            """
        for line in [
            #"_ = try Regex("(?i)\\b\(NSRegularExpression.escapedPattern(for: marker))\\b")"#,
            "let escaped = NSRegularExpression.escapedPattern(for: marker)\n    _ = try Regex(\"(?i)\\\\b\\(escaped)\\\\b\")",
        ] {
            let code = mcp.replacingOccurrences(of: "%@", with: line)
            #expect(try await findings(code, Self.fromInput).isEmpty, "\(line)")
        }
    }

    @Test("23. the SwiftExcelFunctions shape: a worksheet argument compiled as a pattern")
    func worksheetArgument() async throws {
        let code = """
            import Foundation
            enum Functions {
                private static func withRegex(_ args: [CellValue], caseArgument: Int = 2) -> CellValue {
                    guard case .text(let pattern) = args[1].resolved else { return .error(.value) }
                    let expression: NSRegularExpression
                    do {
                        expression = try NSRegularExpression(pattern: pattern, options: [])
                    } catch {
                        return .error(.value)
                    }
                    return .bool(expression.numberOfCaptureGroups > 0)
                }
            }
            """
        let found = try await findings(code, Self.fromInput)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 7)
        #expect(found.first?.message.contains("a document cell (args: [CellValue], via pattern)") == true)
    }

    @Test("26. docc-lint's glob shape, on a command-line value, is a warning")
    func globTranslation() async throws {
        let found = try await findings(inFunction("""
            let pattern = CommandLine.arguments[1]
            _ = text.range(of: pattern.replacingOccurrences(of: "*", with: ".*"), options: .regularExpression)
            """), Self.fromInput)
        #expect(found.count == 1)
    }

    @Test("27. MATCHES with an external operand is regex-from-input, not predicate-injection")
    func matchesOperand() async throws {
        let code = """
            import Vapor
            func search(req: Request) throws {
                let pattern = try req.query.get(String.self, at: "q")
                _ = NSPredicate(format: "name MATCHES %@", pattern)
            }
            """
        let result = try await audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == Self.fromInput }.count == 1)
        #expect(result.diagnostics.filter { $0.ruleId == Self.predicate }.isEmpty)
    }

    @Test("not external under the one-function model: a parameter, a property, a literal operand", arguments: [
        // 18 in the proposal reports a public function's parameter. The model does not cross the
        // function boundary, so the shared model reports it as a parameter, not as input.
        "_ = try NSRegularExpression(pattern: userPattern)",
        // 19 in the proposal: `CustomRulesChecker`'s shape — a property of configuration.
        "_ = try Regex(rule.pattern)",
        #"_ = NSPredicate(format: "name MATCHES %@", "a.*")"#,
        #"_ = try NSRegularExpression(pattern: "^[a-z]+$")"#,
    ])
    func notExternal(line: String) async throws {
        #expect(try await findings(inFunction(line), Self.fromInput).isEmpty)
    }

    // MARK: - Predicate and expression format strings — error

    @Test("28, 30. an interpolated or non-literal NSPredicate format is an error citing CWE-943", arguments: [
        #"_ = NSPredicate(format: "name == '\(text)'")"#,
        "_ = NSPredicate(format: userPattern)",
    ])
    func predicateInjection(line: String) async throws {
        let found = try await findings(inFunction(line), Self.predicate)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.message.contains("[CWE-943]") == true)
    }

    @Test("an NSExpression format from an MCP argument is an error citing CWE-917 and the source")
    func expressionInjection() async throws {
        let code = """
            import Foundation
            func execute(arguments: [String: AnyCodable]?) {
                let formula = arguments?["formula"]?.stringValue ?? "0"
                _ = NSExpression(format: formula)
            }
            """
        let found = try await findings(code, Self.predicate)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("[CWE-917]") == true)
        #expect(found.first?.message.contains("an MCP tool argument") == true)
    }

    @Test("SwiftMCPServer's shape: a formula parameter, no model source, still an error")
    func expressionFromParameter() async throws {
        let code = """
            import Foundation
            public enum ExpressionEvaluator {
                public static func evaluate(_ formula: String) -> Double {
                    let expression = NSExpression(format: formula)
                    return (expression.expressionValue(with: nil, context: nil) as? Double) ?? 0
                }
            }
            """
        let found = try await findings(code, Self.predicate)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 4)
    }

    @Test("29, 31, 32. a literal format, a local constant, and the macro are clean", arguments: [
        #"_ = NSPredicate(format: "name == %@", text)"#,
        #"_ = NSPredicate(format: "age > 18")"#,
        #"_ = NSExpression(format: "1 + 2")"#,
        "_ = #Predicate<Item> { $0.name == text }",
    ])
    func predicateClean(line: String) async throws {
        #expect(try await findings(inFunction(line), Self.predicate).isEmpty)
    }

    @Test("a format bound to a same-file literal constant is clean")
    func predicateConstant() async throws {
        let code = """
            import Foundation
            let byName = "name == %@"
            func f(text: String) { _ = NSPredicate(format: byName, text) }
            """
        #expect(try await findings(code, Self.predicate).isEmpty)
    }

    // MARK: - Acknowledgement, and the bound it must name

    private func worksheetSite(marker: String) -> String {
        """
        import Foundation
        func withRegex(_ args: [CellValue]) throws {
            guard case .text(let pattern) = args[1] else { return }
            \(marker)
            _ = try NSRegularExpression(pattern: pattern)
        }
        """
    }

    @Test("33. an acknowledgement naming a bound is recorded, not reported", arguments: [
        "// SECURITY: pattern is a worksheet argument; subject capped at 32,767 chars, pattern at 255",
        "// SECURITY: repository configuration; analysed at load, matched under a deadline",
        "// SECURITY: the subject is at most 255 characters, checked by the caller above",
    ])
    func boundAccepted(marker: String) async throws {
        let result = try await audit(worksheetSite(marker: marker))
        #expect(!result.diagnostics.contains { $0.ruleId == Self.fromInput })
        let override = try #require(result.overrides.first { $0.ruleId == Self.fromInput })
        #expect(override.lineNumber == 5)
    }

    @Test("a reasoned acknowledgement that names no bound is rejected, and says so")
    func boundMissing() async throws {
        let result = try await audit(worksheetSite(
            marker: "// SECURITY: the workbook author writes these patterns deliberately as part of the spreadsheet"))
        let finding = try #require(result.diagnostics.first { $0.ruleId == Self.fromInput })
        #expect(finding.message.contains("not accepted"))
        #expect(finding.message.contains("names no bound"))
        #expect(!result.overrides.contains { $0.ruleId == Self.fromInput })
    }

    @Test("34. a bare marker is no acknowledgement")
    func bareMarker() async throws {
        let result = try await audit(worksheetSite(marker: "// SECURITY:"))
        #expect(result.diagnostics.contains { $0.ruleId == Self.fromInput })
    }

    @Test("the bound requirement is regex-from-input's alone")
    func boundOnlyForRegexFromInput() async throws {
        let code = """
            import Foundation
            func f(query: String) {
                // SECURITY: the query is built from an allowlisted enum of field names only
                _ = NSPredicate(format: query)
            }
            """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == Self.predicate })
        #expect(result.overrides.contains { $0.ruleId == Self.predicate })
    }

    @Test("namesABound reads words, not substrings", arguments: [
        ("capped at 255", true), ("limit of 1 KB", true), ("max 64 chars", true),
        ("matched under a deadline", true), ("no more than 80", true), ("length <= 80", true),
        ("the capital letters only", false), ("maximal munch is fine", false), ("trusted input", false),
    ])
    func boundWords(reason: String, expected: Bool) {
        #expect(SecurityVisitor.namesABound(reason) == expected)
    }

    // MARK: - Manifest

    @Test("the three rules are in the manifest with their CWEs, severity and OWASP columns", arguments: [
        ("security.regex-catastrophic", ["CWE-1333"], "ERROR", nil as String?),
        ("security.regex-from-input", ["CWE-1333"], "WARNING", nil as String?),
        ("security.predicate-injection", ["CWE-943", "CWE-917"], "ERROR", "A03:2021 Injection" as String?),
    ])
    func manifest(ruleId: String, cwes: [String], severity: String, top10: String?) throws {
        let rule = try #require(SecurityRuleManifest.rules.first { $0.ruleId == ruleId })
        #expect(rule.cwes == cwes)
        #expect(rule.severity == severity)
        #expect(rule.owaspTop10 == top10)
        #expect(rule.owaspMobile == "M4 Insufficient Input/Output Validation")
        let api = ruleId == Self.predicate ? nil : "API4:2023 Unrestricted Resource Consumption"
        #expect(rule.owaspAPI == api)
    }
}
