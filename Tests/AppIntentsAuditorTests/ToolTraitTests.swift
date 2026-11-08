import Foundation
import Testing
@testable import AppIntentsAuditor
import QualityGateCore

/// The tool trait is for custom actions Siri can run. Apple says not to add it to an intent that
/// already conforms to a primary-domain schema (that already reaches Siri), and not to an intent
/// with no custom `perform()` such as a `WidgetConfigurationIntent`.
@Suite("AppIntentVisitor — tool trait")
struct ToolTraitTests {

    private func intent(attribute: String, inheritance: String = "AppIntent", perform: Bool = true) -> String {
        """
        import AppIntents

        \(attribute)
        struct Thing: \(inheritance) {
            static var title: LocalizedStringResource = "Thing"
            static var description: IntentDescription = "Does a thing for the person"
            \(perform ? "func perform() async throws -> some IntentResult { .result() }" : "")
        }
        """
    }

    private func findings(_ source: String, rule: String) -> [Diagnostic] {
        AppIntentVisitor.analyze(source: source, fileName: "T.swift").filter { $0.ruleId == rule }
    }

    // MARK: appintent-tool-no-perform

    @Test("A tool intent with no perform() is a warning")
    func toolWithoutPerform() {
        let result = findings(intent(attribute: "@AppIntent(.tool)", perform: false), rule: "appintent-tool-no-perform")
        #expect(result.count == 1)
        #expect(result.first?.severity == .warning)
        #expect(result.first?.message.contains("'Thing'") == true)
    }

    @Test("A WidgetConfigurationIntent carrying .tool is flagged")
    func widgetConfigurationTool() {
        let source = intent(attribute: "@AppIntent(.tool)", inheritance: "AppIntent, WidgetConfigurationIntent", perform: false)
        #expect(findings(source, rule: "appintent-tool-no-perform").count == 1)
    }

    @Test("A tool intent with perform() is not flagged")
    func toolWithPerform() {
        #expect(findings(intent(attribute: "@AppIntent(.tool)"), rule: "appintent-tool-no-perform").isEmpty)
    }

    @Test("An intent without the tool trait is not this rule's concern")
    func noToolNoPerform() {
        #expect(findings(intent(attribute: "", perform: false), rule: "appintent-tool-no-perform").isEmpty)
    }

    // MARK: appintent-tool-with-siri-schema

    @Test("The tool trait on a primary-domain schema is a note")
    func toolWithPrimarySchema() {
        let result = findings(
            intent(attribute: "@AppIntent(.tool, schema: .photos.openAsset)"), rule: "appintent-tool-with-siri-schema")
        #expect(result.count == 1)
        #expect(result.first?.severity == .note)
        #expect(result.first?.message.contains("photos") == true)
    }

    @Test("The tool trait on a Shortcuts-only schema is what that domain needs, and is not flagged")
    func toolWithShortcutsOnlySchema() {
        let result = findings(
            intent(attribute: "@AppIntent(.tool, schema: .journal.createEntry)"), rule: "appintent-tool-with-siri-schema")
        #expect(result.isEmpty)
    }

    @Test("The tool trait alone, or a schema alone, is not flagged")
    func singleTrait() {
        #expect(findings(intent(attribute: "@AppIntent(.tool)"), rule: "appintent-tool-with-siri-schema").isEmpty)
        #expect(findings(intent(attribute: "@AppIntent(schema: .photos.openAsset)"), rule: "appintent-tool-with-siri-schema").isEmpty)
    }
}
