import Foundation
import Testing
@testable import AppIntentsAuditor
import QualityGateCore

/// Apple asks for an `IntentAuthenticationPolicy` on an entity that carries sensitive data, so Siri
/// does not read it out on a locked device. Whether a property is sensitive is a judgement the
/// checker can only approximate from its name, so the rule has a recorded decline.
@Suite("AppIntentVisitor — sensitive properties")
struct SensitivePropertyTests {

    private func entity(_ members: String, preamble: String = "") -> String {
        """
        import AppIntents

        struct Account: AppEntity {
            static var typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
            var displayRepresentation: DisplayRepresentation { "Account" }
            var id: String
            \(preamble)
            \(members)
        }
        """
    }

    private func run(_ source: String) -> (findings: [Diagnostic], all: [Diagnostic], overrides: [DiagnosticOverride]) {
        let result = AppIntentVisitor.analyzeWithOverrides(source: source, fileName: "T.swift")
        return (result.diagnostics.filter { $0.ruleId == "appintent-sensitive-no-auth" }, result.diagnostics, result.overrides)
    }

    private func property(_ name: String, policy: Bool = false) -> String {
        let extra = policy ? ", authenticationPolicy: .requiresAuthentication" : ""
        return "@Property(title: \"T\", description: \"Described\"\(extra))\n    var \(name): Double"
    }

    @Test("A property named like sensitive data, with no policy, is a warning",
          arguments: ["balance", "accountBalance", "password", "authToken", "annualSalary", "diagnosis"])
    func sensitiveName(name: String) {
        let result = run(entity(property(name)))
        #expect(result.findings.count == 1)
        #expect(result.findings.first?.severity == .warning)
        #expect(result.findings.first?.message.contains("'\(name)'") == true)
    }

    @Test("An ordinary name is not flagged", arguments: ["name", "title", "createdAt", "tokenizerCount0"])
    func ordinaryName(name: String) {
        // `tokenizerCount0` shares letters with `token` but is not the word.
        #expect(run(entity(property(name))).findings.isEmpty)
    }

    @Test("A property-level policy satisfies the rule")
    func propertyPolicy() {
        #expect(run(entity(property("balance", policy: true))).findings.isEmpty)
    }

    @Test("An entity-level policy satisfies the rule for every property")
    func entityPolicy() {
        let preamble = "static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication"
        #expect(run(entity(property("balance"), preamble: preamble)).findings.isEmpty)
    }

    @Test("An internal property never reaches Siri and is not flagged")
    func internalProperty() {
        let member = "@Property(title: \"T\", description: \"Described\", visibility: .internal)\n    var password: String"
        #expect(run(entity(member)).findings.isEmpty)
    }

    @Test("A decline with a reason clears the finding and is recorded")
    func declineWithReason() {
        let member = "// appintents:exempt auth — a running total of public donations, nothing personal\n    "
            + property("balance")
        let result = run(entity(member))
        #expect(result.findings.isEmpty)
        #expect(result.overrides.count == 1)
    }

    @Test("A decline with no reason does not count and is reported")
    func declineWithoutReason() {
        let member = "// appintents:exempt auth\n    " + property("balance")
        let result = run(entity(member))
        #expect(result.findings.count == 1)
        #expect(result.all.contains { $0.ruleId == "appintent.exempt-no-justification" })
    }

    @Test("A decline for another surface does not clear it")
    func wrongSurface() {
        let member = "// appintents:exempt siri — not for Siri\n    " + property("balance")
        #expect(run(entity(member)).findings.count == 1)
    }
}

/// `isDiscoverable = false` hides an intent from Shortcuts. With `.tool` it is still a Siri tool,
/// which is legal and may be intended, but is worth seeing early.
@Suite("AppIntentVisitor — hidden tool")
struct HiddenToolTests {

    private func intent(attribute: String, hidden: Bool) -> String {
        """
        import AppIntents

        \(attribute)
        struct Thing: AppIntent {
            static var title: LocalizedStringResource = "Thing"
            static var description: IntentDescription = "Does a thing for the person"
            \(hidden ? "static var isDiscoverable: Bool = false" : "")
            func perform() async throws -> some IntentResult { .result() }
        }
        """
    }

    private func findings(_ source: String) -> [Diagnostic] {
        AppIntentVisitor.analyze(source: source, fileName: "T.swift").filter { $0.ruleId == "appintent-hidden-tool" }
    }

    @Test("A tool intent hidden from Shortcuts is a warning")
    func hiddenTool() {
        let result = findings(intent(attribute: "@AppIntent(.tool)", hidden: true))
        #expect(result.count == 1)
        #expect(result.first?.severity == .warning)
        #expect(result.first?.message.contains("'Thing'") == true)
    }

    @Test("A tool intent visible to Shortcuts is not flagged")
    func visibleTool() {
        #expect(findings(intent(attribute: "@AppIntent(.tool)", hidden: false)).isEmpty)
    }

    @Test("Hidden from Shortcuts with no tool trait is not this rule's concern")
    func hiddenNotTool() {
        #expect(findings(intent(attribute: "", hidden: true)).isEmpty)
    }

    @Test("A schema-only intent hidden from Shortcuts is not flagged")
    func hiddenSchemaOnly() {
        #expect(findings(intent(attribute: "@AppIntent(schema: .photos.openAsset)", hidden: true)).isEmpty)
    }

    @Test("`.tool` combined with a schema counts as a tool")
    func toolWithSchema() {
        #expect(findings(intent(attribute: "@AppIntent(.tool, schema: .journal.createEntry)", hidden: true)).count == 1)
    }
}
