import Foundation
import Testing
@testable import AppIntentsAuditor
import QualityGateCore

/// Apple's Siri AI Developer Preview (27.3) asks for a `description` on every property a custom
/// entity exposes: Siri reads it to decide what the property means, as it reads an intent's.
/// `visibility: .internal` keeps a property from Siri and Shortcuts, so it needs none.
@Suite("AppIntentVisitor — entity property descriptions")
struct EntityPropertyDescriptionTests {

    private func entity(_ members: String, inheritance: String = "AppEntity") -> String {
        """
        import AppIntents

        struct Account: \(inheritance) {
            static var typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
            var displayRepresentation: DisplayRepresentation { "Account" }
            var id: String
            \(members)
        }
        """
    }

    private func findings(_ source: String) -> [Diagnostic] {
        AppIntentVisitor.analyze(source: source, fileName: "T.swift")
            .filter { $0.ruleId == "appintent-property-no-description" }
    }

    @Test("A @Property with no description is a warning naming the property and entity",
          arguments: ["Property", "DeferredProperty", "ComputedProperty"])
    func missingDescription(wrapper: String) {
        let result = findings(entity("@\(wrapper)(title: \"Name\")\n    var name: String"))
        #expect(result.count == 1)
        #expect(result.first?.severity == .warning)
        #expect(result.first?.message.contains("'name'") == true)
        #expect(result.first?.message.contains("'Account'") == true)
    }

    @Test("A bare @Property with no arguments is flagged")
    func bareProperty() {
        #expect(findings(entity("@Property\n    var name: String")).count == 1)
    }

    @Test("A description satisfies the rule",
          arguments: ["Property", "DeferredProperty", "ComputedProperty"])
    func describedProperty(wrapper: String) {
        let member = "@\(wrapper)(title: \"Name\", description: \"What the account is called\")\n    var name: String"
        #expect(findings(entity(member)).isEmpty)
    }

    @Test("An internal property is hidden from Siri and needs no description")
    func internalVisibility() {
        let member = "@Property(title: \"Token\", visibility: .internal)\n    var token: String"
        #expect(findings(entity(member)).isEmpty)
    }

    @Test("Properties that are not entity properties are not flagged")
    func plainMembers() {
        #expect(findings(entity("var cache: [String] = []")).isEmpty)
    }

    @Test("A @Property on a type that is not an AppEntity is not flagged")
    func notAnEntity() {
        let source = """
        struct Plain {
            @Property(title: "Name")
            var name: String
        }
        """
        #expect(findings(source).isEmpty)
    }

    @Test("Each undescribed property is reported at its own line")
    func eachPropertyOwnLine() {
        let members = """
        @Property(title: "A")
            var a: String
            @Property(title: "B", description: "Second")
            var b: String
            @Property(title: "C")
            var c: String
        """
        let result = findings(entity(members))
        #expect(result.count == 2)
        #expect(result.map(\.lineNumber) == [7, 11])
    }
}
