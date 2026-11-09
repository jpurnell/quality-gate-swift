import Foundation
import Testing
@testable import AppIntentsAuditor
import QualityGateCore

/// Two rules that need the whole project, because an entity's conformances, its query and the
/// intents that use it are rarely in one file. Both are notes: an entity Siri cannot find or
/// pass along still works from Shortcuts, and keeping content out of Spotlight is a legitimate
/// decision (Vault makes it on purpose), so neither fails `--strict`.
@Suite("EntityReachability — findable and transferable entities")
struct EntityReachabilityTests {

    private func run(_ sources: [String: String], rule: String) -> [Diagnostic] {
        EntityReachability.analyze(sources: sources).filter { $0.ruleId == rule }
    }

    private let entity = """
        import AppIntents
        struct Book: AppEntity {
            static var typeDisplayRepresentation: TypeDisplayRepresentation = "Book"
            var id: String
            var displayRepresentation: DisplayRepresentation { "Book" }
            static var defaultQuery = BookQuery()
        }
        """

    // MARK: appintent-entity-not-findable

    @Test("An entity that is neither indexed nor enumerable is a note")
    func notFindable() {
        let source = entity + "\nstruct BookQuery: EntityQuery { func entities(for ids: [String]) async throws -> [Book] { [] } }"
        let result = run(["A.swift": source], rule: "appintent-entity-not-findable")
        #expect(result.count == 1)
        #expect(result.first?.severity == .note)
        #expect(result.first?.message.contains("'Book'") == true)
    }

    @Test("IndexedEntity on the declaration makes it findable")
    func indexedOnDeclaration() {
        let source = entity.replacingOccurrences(of: "Book: AppEntity", with: "Book: AppEntity, IndexedEntity")
        #expect(run(["A.swift": source], rule: "appintent-entity-not-findable").isEmpty)
    }

    @Test("IndexedEntity added by an extension in another file makes it findable")
    func indexedByExtension() {
        let result = run(
            ["A.swift": entity, "B.swift": "import AppIntents\nextension Book: IndexedEntity {}"],
            rule: "appintent-entity-not-findable")
        #expect(result.isEmpty)
    }

    @Test("A protocol that inherits IndexedEntity counts")
    func indexedThroughProtocol() {
        let source = "import AppIntents\nprotocol Searchable: IndexedEntity {}\n"
            + entity.replacingOccurrences(of: "Book: AppEntity", with: "Book: AppEntity, Searchable")
        #expect(run(["A.swift": source], rule: "appintent-entity-not-findable").isEmpty)
    }

    @Test("An entity whose query is an EnumerableEntityQuery is findable, by typealias")
    func enumerableByTypealias() {
        let query = "struct BookQuery: EnumerableEntityQuery { typealias Entity = Book; func allEntities() async throws -> [Book] { [] } }"
        #expect(run(["A.swift": entity + "\n" + query], rule: "appintent-entity-not-findable").isEmpty)
    }

    @Test("An EnumerableEntityQuery in another file, found by the allEntities() result")
    func enumerableByAllEntities() {
        let query = "import AppIntents\nstruct Library: EnumerableEntityQuery { func allEntities() async throws -> [Book] { [] } }"
        let source = entity.replacingOccurrences(of: "BookQuery()", with: "Library()")
        #expect(run(["A.swift": source, "B.swift": query], rule: "appintent-entity-not-findable").isEmpty)
    }

    @Test("A query declared enumerable by an extension counts")
    func enumerableByExtension() {
        let query = "struct BookQuery { func allEntities() async throws -> [Book] { [] } }\nextension BookQuery: EnumerableEntityQuery {}"
        #expect(run(["A.swift": entity + "\n" + query], rule: "appintent-entity-not-findable").isEmpty)
    }

    @Test("Only the unfindable entity is reported")
    func onlyOne() {
        let other = "struct Shelf: AppEntity, IndexedEntity { var id: String }"
        let result = run(["A.swift": entity + "\n" + other], rule: "appintent-entity-not-findable")
        #expect(result.count == 1)
        #expect(result.first?.message.contains("'Book'") == true)
    }

    // MARK: appintent-entity-not-transferable

    private func tool(parameterType: String = "Book", returns: String = "some IntentResult", attribute: String = "@AppIntent(.tool)") -> String {
        """
        import AppIntents
        \(attribute)
        struct ReadBook: AppIntent {
            static var title: LocalizedStringResource = "Read"
            @Parameter(title: "Book") var book: \(parameterType)
            func perform() async throws -> \(returns) { .result() }
        }
        """
    }

    @Test("An entity taken as a parameter by a tool intent, without Transferable, is a note")
    func parameterNotTransferable() {
        let result = run(["A.swift": entity, "T.swift": tool()], rule: "appintent-entity-not-transferable")
        #expect(result.count == 1)
        #expect(result.first?.severity == .note)
        #expect(result.first?.message.contains("'Book'") == true)
        #expect(result.first?.message.contains("'ReadBook'") == true)
    }

    @Test("Optional and array parameters are looked through", arguments: ["Book?", "[Book]", "Array<Book>", "[Book]?"])
    func wrapped(parameterType: String) {
        let result = run(["A.swift": entity, "T.swift": tool(parameterType: parameterType)], rule: "appintent-entity-not-transferable")
        #expect(result.count == 1)
    }

    @Test("An entity returned by a tool intent is a use too")
    func returnedValue() {
        let source = tool(parameterType: "String", returns: "some IntentResult & ReturnsValue<Book>")
        #expect(run(["A.swift": entity, "T.swift": source], rule: "appintent-entity-not-transferable").count == 1)
    }

    @Test("Transferable on the declaration, or by extension, satisfies it")
    func transferable() {
        let declared = entity.replacingOccurrences(of: "Book: AppEntity", with: "Book: AppEntity, Transferable")
        #expect(run(["A.swift": declared, "T.swift": tool()], rule: "appintent-entity-not-transferable").isEmpty)
        let extended = ["A.swift": entity, "T.swift": tool(), "E.swift": "import AppIntents\nextension Book: Transferable {}"]
        #expect(run(extended, rule: "appintent-entity-not-transferable").isEmpty)
    }

    @Test("An intent that is not a tool does not make its entities need Transferable")
    func notATool() {
        #expect(run(["A.swift": entity, "T.swift": tool(attribute: "")], rule: "appintent-entity-not-transferable").isEmpty)
    }

    @Test("An entity no tool uses is not reported")
    func unused() {
        #expect(run(["A.swift": entity], rule: "appintent-entity-not-transferable").isEmpty)
    }

    @Test("Several tools using one entity give one finding naming them")
    func oneFindingManyTools() {
        let second = tool().replacingOccurrences(of: "ReadBook", with: "ShelveBook")
        let result = run(["A.swift": entity, "T.swift": tool(), "U.swift": second], rule: "appintent-entity-not-transferable")
        #expect(result.count == 1)
        #expect(result.first?.message.contains("ReadBook") == true)
        #expect(result.first?.message.contains("ShelveBook") == true)
    }

    @Test("A file without import AppIntents is not read")
    func noImport() {
        #expect(EntityReachability.analyze(sources: ["A.swift": "struct Book: AppEntity {}"]).isEmpty)
    }
}
