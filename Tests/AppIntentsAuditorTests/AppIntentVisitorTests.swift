import Foundation
import Testing
@testable import AppIntentsAuditor
import QualityGateCore

@Suite("AppIntentVisitor — Intent Completeness")
struct IntentCompletenessTests {

    @Test("Golden path — well-formed intent produces no diagnostics")
    func goldenPath() {
        let source = """
        import AppIntents

        @AssistantIntent(schema: .system.search)
        struct SearchIntent: AppIntent {
            static var title: LocalizedStringResource = "Search Items"

            static var description: IntentDescription = IntentDescription(
                "Searches items in the catalog by keyword",
                searchKeywords: ["find", "lookup"]
            )

            @Parameter(title: "Query")
            var query: String

            func perform() async throws -> some IntentResult {
                .result()
            }
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        #expect(diagnostics.isEmpty)
    }

    @Test("Missing IntentDescription emits appintent-no-description")
    func missingDescription() throws {
        let source = """
        import AppIntents

        struct OpenApp: AppIntent {
            static var title: LocalizedStringResource = "Open App"

            func perform() async throws -> some IntentResult {
                .result()
            }
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        let rule = try #require(diagnostics.first { $0.ruleId == "appintent-no-description" })
        #expect(rule.severity == .warning)
    }

    @Test("Missing @Parameter title emits appintent-param-no-title")
    func missingParamTitle() throws {
        let source = """
        import AppIntents

        struct SearchIntent: AppIntent {
            static var title: LocalizedStringResource = "Search"
            static var description: IntentDescription = "Searches things for the user"

            @Parameter var query: String

            func perform() async throws -> some IntentResult {
                .result()
            }
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        let rule = try #require(diagnostics.first { $0.ruleId == "appintent-param-no-title" })
        #expect(rule.severity == .warning)
    }

    @Test("Missing @AssistantIntent emits appintent-no-assistant-schema")
    func missingAssistantIntent() throws {
        let source = """
        import AppIntents

        struct OpenApp: AppIntent {
            static var title: LocalizedStringResource = "Open App"
            static var description: IntentDescription = "Opens the application to the main screen"

            func perform() async throws -> some IntentResult {
                .result()
            }
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        let rule = try #require(diagnostics.first { $0.ruleId == "appintent-no-assistant-schema" })
        #expect(rule.severity == .warning)
    }

    @Test("No import AppIntents returns empty diagnostics")
    func noImportSkips() {
        let source = """
        struct MyThing {
            let name: String
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        #expect(diagnostics.isEmpty)
    }

    @Test("Multiple intents — only incomplete ones emit diagnostics")
    func multipleIntents() {
        let source = """
        import AppIntents

        @AssistantIntent(schema: .system.search)
        struct GoodIntent: AppIntent {
            static var title: LocalizedStringResource = "Good"
            static var description: IntentDescription = "Does good things for the user"
            @Parameter(title: "Input") var input: String
            func perform() async throws -> some IntentResult { .result() }
        }

        struct BadIntent: AppIntent {
            static var title: LocalizedStringResource = "Bad"
            func perform() async throws -> some IntentResult { .result() }
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        let descriptionDiags = diagnostics.filter { $0.ruleId == "appintent-no-description" }
        let assistantDiags = diagnostics.filter { $0.ruleId == "appintent-no-assistant-schema" }
        #expect(descriptionDiags.count == 1)
        #expect(assistantDiags.count == 1)
    }
}

@Suite("AppIntentVisitor — Entity Completeness")
struct EntityCompletenessTests {

    @Test("Entity missing displayRepresentation emits warning")
    func entityMissingDisplay() throws {
        let source = """
        import AppIntents

        struct Item: AppEntity {
            static var typeDisplayRepresentation: TypeDisplayRepresentation = "Item"
            var id: String
            static var defaultQuery = ItemQuery()
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        let rule = try #require(diagnostics.first { $0.ruleId == "appintent-entity-no-display" })
        #expect(rule.severity == .warning)
    }

    @Test("Entity missing typeDisplayRepresentation emits warning")
    func entityMissingTypeDisplay() throws {
        let source = """
        import AppIntents

        struct Item: AppEntity {
            var id: String
            var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\\(id)") }
            static var defaultQuery = ItemQuery()
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        let rule = try #require(diagnostics.first { $0.ruleId == "appintent-entity-no-type-display" })
        #expect(rule.severity == .warning)
    }

    @Test("Entity without @AssistantEntity emits warning")
    func entityNotAssistant() throws {
        let source = """
        import AppIntents

        struct Item: AppEntity {
            static var typeDisplayRepresentation: TypeDisplayRepresentation = "Item"
            var id: String
            var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\\(id)") }
            static var defaultQuery = ItemQuery()
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        let rule = try #require(diagnostics.first { $0.ruleId == "appintent-entity-not-assistant" })
        #expect(rule.severity == .warning)
    }
}

@Suite("AppIntentVisitor — Enum Completeness")
struct EnumCompletenessTests {

    @Test("Enum missing typeDisplayRepresentation emits warning")
    func enumMissingTypeDisplay() throws {
        let source = """
        import AppIntents

        enum Priority: String, AppEnum {
            case low, medium, high
            static var caseDisplayRepresentations: [Priority: DisplayRepresentation] = [
                .low: "Low", .medium: "Medium", .high: "High"
            ]
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        let rule = try #require(diagnostics.first { $0.ruleId == "appintent-enum-no-display" })
        #expect(rule.severity == .warning)
    }

    @Test("Enum without @AssistantEnum emits warning")
    func enumNotAssistant() throws {
        let source = """
        import AppIntents

        enum Priority: String, AppEnum {
            case low, medium, high
            static var typeDisplayRepresentation: TypeDisplayRepresentation = "Priority"
            static var caseDisplayRepresentations: [Priority: DisplayRepresentation] = [
                .low: "Low", .medium: "Medium", .high: "High"
            ]
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        let rule = try #require(diagnostics.first { $0.ruleId == "appintent-enum-not-assistant" })
        #expect(rule.severity == .warning)
    }
}

@Suite("AppIntentVisitor — Validation trace from proposal")
struct ValidationTraceTests {

    @Test("Proposal trace 1: OpenPortfolio intent")
    func openPortfolioTrace() {
        let source = """
        import AppIntents

        struct OpenPortfolio: AppIntent {
            static var title: LocalizedStringResource = "Open Portfolio"
            @Parameter var portfolio: String
            func perform() async throws -> some IntentResult { .result() }
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        let ruleIds = Set(diagnostics.map(\.ruleId).compactMap { $0 })
        #expect(ruleIds.contains("appintent-no-description"))
        #expect(ruleIds.contains("appintent-no-assistant-schema"))
        #expect(ruleIds.contains("appintent-param-no-title"))
    }

    @Test("Proposal trace 2: Priority enum with missing case display")
    func priorityEnumTrace() {
        let source = """
        import AppIntents

        enum Priority: String, AppEnum {
            case low, medium, high
            static var typeDisplayRepresentation: TypeDisplayRepresentation = "Priority"
            static var caseDisplayRepresentations: [Priority: DisplayRepresentation] = [
                .low: "Low",
                .high: "High",
            ]
        }
        """
        let diagnostics = AppIntentVisitor.analyze(source: source, fileName: "Test.swift")
        let ruleIds = Set(diagnostics.map(\.ruleId).compactMap { $0 })
        #expect(ruleIds.contains("appintent-enum-case-no-display"))
        #expect(ruleIds.contains("appintent-enum-not-assistant"))
    }
}
