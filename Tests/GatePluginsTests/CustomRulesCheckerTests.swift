import Foundation
import Testing
@testable import GatePlugins
@testable import QualityGateCore

/// Phase 4b Tier 1 — declarative custom rules in `.quality-gate.yml`.
///
/// The contract under test: rules report under their own id with
/// `origin: custom-rule`, include/exclude scope them, `// custom:exempt`
/// is recorded rather than silent, a bad pattern is a visible finding,
/// and the declared severity is what gates.
@Suite("CustomRulesChecker", .serialized)
struct CustomRulesCheckerTests {

    // MARK: - Fixtures

    /// A throwaway package root with one ViewModel and one plain source file.
    private func makeFixtureRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-rules-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        import Foundation
        final class LoginViewModel {
            func report() {
                print("logging in")
            }
        }
        """.write(to: sources.appendingPathComponent("LoginViewModel.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        func helper() {
            print("plain helper")
        }
        """.write(to: sources.appendingPathComponent("Helper.swift"), atomically: true, encoding: .utf8)
        return root.path
    }

    private func rule(
        id: String = "house.no-print",
        pattern: String = #"print\("#,
        include: [String] = [],
        exclude: [String] = [],
        message: String = "use os.Logger, not print()",
        severity: Diagnostic.Severity = .warning
    ) -> CustomRuleConfig {
        CustomRuleConfig(
            id: id, pattern: pattern, include: include, exclude: exclude,
            message: message, severity: severity)
    }

    // MARK: - Config decode

    @Test("minimal YAML entry decodes with warning severity and open scope")
    func configDefaults() throws {
        let json = #"{"id":"house.no-print","pattern":"print\\(","message":"no print"}"#
        let decoded = try JSONDecoder().decode(CustomRuleConfig.self, from: Data(json.utf8))
        #expect(decoded.severity == .warning)
        #expect(decoded.include.isEmpty)
        #expect(decoded.exclude.isEmpty)
    }

    @Test("a configuration without customRules decodes to an empty rule set")
    func configAbsent() throws {
        let decoded = try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
        #expect(decoded.customRules.isEmpty)
    }

    // MARK: - Matching

    @Test("a match reports under the rule's id with origin custom-rule at the right line")
    func matchProducesTaggedDiagnostic() throws {
        let root = try makeFixtureRoot()
        let files = CustomRulesChecker.swiftFiles(under: root)
        let findings = CustomRulesChecker.apply(rule: rule(), to: files, root: root)
        #expect(findings.diagnostics.count == 2)
        let inViewModel = try #require(findings.diagnostics.first {
            $0.filePath?.hasSuffix("LoginViewModel.swift") == true
        })
        #expect(inViewModel.ruleId == "house.no-print")
        #expect(inViewModel.origin == "custom-rule")
        #expect(inViewModel.message == "use os.Logger, not print()")
        #expect(inViewModel.severity == .warning)
        #expect(inViewModel.lineNumber == 4)
    }

    @Test("include globs scope the rule; exclude wins over include")
    func includeExcludeScoping() {
        let scoped = rule(include: ["Sources/*/*ViewModel*"])
        #expect(CustomRulesChecker.included("Sources/App/LoginViewModel.swift", rule: scoped))
        #expect(!CustomRulesChecker.included("Sources/App/Helper.swift", rule: scoped))

        let excluded = rule(include: ["Sources/"], exclude: ["Sources/App/Helper.swift"])
        #expect(CustomRulesChecker.included("Sources/App/LoginViewModel.swift", rule: excluded))
        #expect(!CustomRulesChecker.included("Sources/App/Helper.swift", rule: excluded))

        let prefix = rule(exclude: ["Tests/"])
        #expect(!CustomRulesChecker.included("Tests/AppTests/HelperTests.swift", rule: prefix))
    }

    // MARK: - Escape hatch

    @Test("// custom:exempt suppresses the finding and records the override")
    func exemptIsRecordedNotSilent() throws {
        let root = try makeFixtureRoot()
        let exempted = URL(fileURLWithPath: root)
            .appendingPathComponent("Sources/App/Exempted.swift")
        try """
        func once() {
            print("allowed here") // custom:exempt
        }
        """.write(to: exempted, atomically: true, encoding: .utf8)

        let findings = CustomRulesChecker.apply(
            rule: rule(include: ["Sources/App/Exempted.swift"]),
            to: CustomRulesChecker.swiftFiles(under: root),
            root: root)
        #expect(findings.diagnostics.isEmpty)
        #expect(findings.overrides.count == 1)
        let override = try #require(findings.overrides.first)
        #expect(override.ruleId == "house.no-print")
        #expect(override.lineNumber == 2)
    }

    // MARK: - Failure visibility

    @Test("an invalid pattern is a visible error finding, never a crash or a skip")
    func invalidPatternIsAFinding() throws {
        let root = try makeFixtureRoot()
        let findings = CustomRulesChecker.apply(
            rule: rule(pattern: "(unclosed"),
            to: CustomRulesChecker.swiftFiles(under: root),
            root: root)
        #expect(findings.diagnostics.count == 1)
        let diagnostic = try #require(findings.diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.ruleId == "house.no-print")
        #expect(diagnostic.message.contains("invalid pattern"))
    }

    @Test("a rule's wall time above the threshold surfaces as a note")
    func slowRuleIsVisible() async throws {
        let root = try makeFixtureRoot()
        var configuration = Configuration()
        configuration.customRules = [rule()]
        let checker = CustomRulesChecker(root: root, slowRuleThreshold: .zero)
        let result = try await checker.check(configuration: configuration)
        #expect(result.diagnostics.contains { $0.ruleId == "custom-rules.slow-rule" })
    }

    // MARK: - Gating is the user's declaration

    @Test("declared severity is what gates: error fails, warning warns, no rules skip")
    func severityDeclaresGating() async throws {
        let root = try makeFixtureRoot()

        var erroring = Configuration()
        erroring.customRules = [rule(severity: .error)]
        let failed = try await CustomRulesChecker(root: root).check(configuration: erroring)
        #expect(failed.status == .failed)

        var warning = Configuration()
        warning.customRules = [rule(severity: .warning)]
        let warned = try await CustomRulesChecker(root: root).check(configuration: warning)
        #expect(warned.status == .warning)

        var clean = Configuration()
        clean.customRules = [rule(pattern: "definitelyNotInTheFixture")]
        let passed = try await CustomRulesChecker(root: root).check(configuration: clean)
        #expect(passed.status == .passed)

        let unconfigured = try await CustomRulesChecker(root: root).check(configuration: Configuration())
        #expect(unconfigured.status == .skipped)
    }
}
