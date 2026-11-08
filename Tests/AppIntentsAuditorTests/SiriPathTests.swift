import Foundation
import Testing
@testable import AppIntentsAuditor
import QualityGateCore

/// Apple's Siri AI Developer Preview (27.3) gives a custom intent two routes to Siri: a
/// system schema (`@AppIntent(schema:)`), or the tool trait (`@AppIntent(.tool)`). The checker
/// used to look for an attribute spelled `@AssistantIntent`, which is a protocol and not a
/// macro, so it flagged intents that had already adopted a schema.
@Suite("AppIntentVisitor — Siri path")
struct SiriPathTests {

    private func intent(attribute: String = "", inheritance: String = "AppIntent", perform: Bool = true) -> String {
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

    private func ids(_ source: String) -> [String] {
        AppIntentVisitor.analyze(source: source, fileName: "T.swift").compactMap(\.ruleId)
    }

    @Test("Each real route to Siri satisfies the rule",
          arguments: [
            "@AppIntent(.tool)",
            "@AppIntent(schema: .photos.openAsset)",
            "@AppIntent(.tool, schema: .journal.createEntry)",
          ])
    func attributeRoutes(attribute: String) {
        #expect(!ids(intent(attribute: attribute)).contains("appintent-no-assistant-schema"))
    }

    @Test("Conforming to the AssistantIntent or ToolIntent protocol satisfies the rule",
          arguments: ["AppIntent, AssistantIntent", "AppIntent, ToolIntent"])
    func protocolRoutes(inheritance: String) {
        #expect(!ids(intent(inheritance: inheritance)).contains("appintent-no-assistant-schema"))
    }

    @Test("A custom intent with a perform() and no route is flagged, with a fix that exists")
    func customIntentFlagged() throws {
        let diagnostics = AppIntentVisitor.analyze(source: intent(), fileName: "T.swift")
        let rule = try #require(diagnostics.first { $0.ruleId == "appintent-no-assistant-schema" })
        let text = rule.message + (rule.suggestedFix ?? "")
        #expect(text.contains("@AppIntent(.tool)"))
        #expect(!text.contains("@AssistantIntent"), "that spelling is a protocol, not an attribute")
    }

    @Test("A WidgetConfigurationIntent is not asked to be a tool")
    func widgetConfigurationExempt() {
        let source = intent(inheritance: "WidgetConfigurationIntent", perform: false)
            .replacingOccurrences(of: "struct Thing: WidgetConfigurationIntent", with: "struct Thing: AppIntent, WidgetConfigurationIntent")
        #expect(!ids(source).contains("appintent-no-assistant-schema"))
    }

    @Test("An intent with no perform() has no action for Siri to run")
    func noPerformExempt() {
        #expect(!ids(intent(perform: false)).contains("appintent-no-assistant-schema"))
    }

    // MARK: Entities and enums

    @Test("A custom entity without a schema is a note, not a warning")
    func entityIsAdvisory() throws {
        let source = """
        import AppIntents
        struct Item: AppEntity {
            static var typeDisplayRepresentation: TypeDisplayRepresentation = "Item"
            var id: String
            var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\\(id)") }
            static var defaultQuery = ItemQuery()
        }
        """
        let rule = try #require(AppIntentVisitor.analyze(source: source, fileName: "T.swift")
            .first { $0.ruleId == "appintent-entity-not-assistant" })
        #expect(rule.severity == .note)
        #expect(!rule.message.contains("@AssistantEntity"))
    }

    @Test("An entity that adopts a schema, by macro or protocol, is not mentioned",
          arguments: [("@AppEntity(schema: .photos.asset)", "AppEntity"), ("", "AppEntity, AssistantEntity")])
    func entityAdopted(attribute: String, inheritance: String) {
        let source = """
        import AppIntents
        \(attribute)
        struct Item: \(inheritance) {
            static var typeDisplayRepresentation: TypeDisplayRepresentation = "Item"
            var id: String
            var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\\(id)") }
            static var defaultQuery = ItemQuery()
        }
        """
        #expect(!ids(source).contains("appintent-entity-not-assistant"))
    }

    @Test("A custom enum without a schema is a note; one that adopts a schema is not mentioned")
    func enumAdvisory() throws {
        func source(_ attribute: String) -> String {
            """
            import AppIntents
            \(attribute)
            enum Priority: String, AppEnum {
                case low
                static var typeDisplayRepresentation: TypeDisplayRepresentation = "Priority"
                static var caseDisplayRepresentations: [Priority: DisplayRepresentation] = [.low: "Low"]
            }
            """
        }
        let bare = try #require(AppIntentVisitor.analyze(source: source(""), fileName: "T.swift")
            .first { $0.ruleId == "appintent-enum-not-assistant" })
        #expect(bare.severity == .note)
        #expect(!ids(source("@AppEnum(schema: .photos.assetType)")).contains("appintent-enum-not-assistant"))
    }
}
