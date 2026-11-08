import Foundation
import Testing
@testable import AppIntentsAuditor
import QualityGateCore

/// Apple's schema collection splits into primary domains, which reach Siri, and Shortcuts-specific
/// domains, which support Shortcuts but not Siri. An intent that adopts a Shortcuts-specific schema
/// looks finished and is invisible to Siri unless it also carries the tool trait.
@Suite("AppIntentVisitor — Shortcuts-only schemas")
struct ShortcutsOnlySchemaTests {

    private func intent(attribute: String) -> String {
        """
        import AppIntents

        \(attribute)
        struct Thing: AppIntent {
            static var title: LocalizedStringResource = "Thing"
            static var description: IntentDescription = "Does a thing for the person"
            func perform() async throws -> some IntentResult { .result() }
        }
        """
    }

    private func findings(_ attribute: String) -> [Diagnostic] {
        AppIntentVisitor.analyze(source: intent(attribute: attribute), fileName: "T.swift")
            .filter { $0.ruleId == "appintent-schema-shortcuts-only" }
    }

    @Test("A schema from a Shortcuts-specific domain, with no tool trait, is a warning",
          arguments: [
            "@AppIntent(schema: .journal.createEntry)",
            "@AppIntent(schema: .books.openBook)",
            "@AppIntent(schema: .browser.openTab)",
            "@AppIntent(schema: .files.openFile)",
            "@AppIntent(schema: .presentation.openPresentation)",
            "@AppIntent(schema: .reader.openArticle)",
            "@AppIntent(schema: .spreadsheet.openSpreadsheet)",
            "@AppIntent(schema: .whiteboard.openBoard)",
            "@AppIntent(schema: .wordProcessor.openDocument)",
          ])
    func shortcutsOnly(attribute: String) {
        let result = findings(attribute)
        #expect(result.count == 1)
        #expect(result.first?.severity == .warning)
        #expect(result.first?.message.contains("'Thing'") == true)
    }

    @Test("Adding the tool trait satisfies the rule")
    func withToolTrait() {
        #expect(findings("@AppIntent(.tool, schema: .journal.createEntry)").isEmpty)
    }

    @Test("A primary-domain schema reaches Siri and is not flagged",
          arguments: [
            "@AppIntent(schema: .photos.openAsset)",
            "@AppIntent(schema: .system.search)",
            "@AppIntent(schema: .mail.sendDraft)",
          ])
    func primaryDomain(attribute: String) {
        #expect(findings(attribute).isEmpty)
    }

    @Test("An intent with no schema argument is not flagged")
    func noSchema() {
        #expect(findings("@AppIntent(.tool)").isEmpty)
        #expect(findings("").isEmpty)
    }

    @Test("Protocol conformance to ToolIntent also counts as the tool trait")
    func toolProtocol() {
        let source = """
        @AppIntent(schema: .journal.createEntry)
        struct Thing: AppIntent, ToolIntent {
            static var title: LocalizedStringResource = "Thing"
            static var description: IntentDescription = "Does a thing for the person"
            func perform() async throws -> some IntentResult { .result() }
        }
        """
        let result = AppIntentVisitor.analyze(source: source, fileName: "T.swift")
            .filter { $0.ruleId == "appintent-schema-shortcuts-only" }
        #expect(result.isEmpty)
    }

    @Test("The finding is reported at the intent's name and says how to reach Siri")
    func messageAndFix() {
        let result = findings("@AppIntent(schema: .journal.createEntry)")
        #expect(result.first?.suggestedFix?.contains(".tool") == true)
        #expect(result.first?.message.contains("journal") == true)
    }
}
