import Foundation
import Testing
@testable import AppIntentsAuditor
import QualityGateCore

/// A `@Parameter` that `perform()` never reads is a question Siri asks and then ignores. It is the
/// App Intents analogue of `mcp-unused-property`. A parameter read by a helper the intent calls
/// is used, so every function body in the intent counts, not only `perform()`.
@Suite("AppIntentVisitor — unused parameters")
struct UnusedParameterTests {

    private func intent(parameters: String, body: String, extra: String = "") -> String {
        """
        import AppIntents

        struct Thing: AppIntent {
            static var title: LocalizedStringResource = "Thing"
            static var description: IntentDescription = "Does a thing for the person"
            \(parameters)
            func perform() async throws -> some IntentResult {
                \(body)
                return .result()
            }
            \(extra)
        }
        """
    }

    private func findings(_ source: String) -> [Diagnostic] {
        AppIntentVisitor.analyze(source: source, fileName: "T.swift").filter { $0.ruleId == "appintent-param-unused" }
    }

    private let amount = "@Parameter(title: \"Amount\")\n    var amount: Int"

    @Test("A parameter perform() never reads is a warning naming it")
    func unused() {
        let result = findings(intent(parameters: amount, body: "_ = 1"))
        #expect(result.count == 1)
        #expect(result.first?.severity == .warning)
        #expect(result.first?.message.contains("'amount'") == true)
        #expect(result.first?.message.contains("'Thing'") == true)
    }

    @Test("A parameter read in perform() is used", arguments: [
        "_ = amount",
        "_ = self.amount",
        "_ = $amount",
        "let x = [1].map { $0 + amount }; _ = x",
        "if amount > 0 { _ = 1 }",
    ])
    func readInPerform(body: String) {
        #expect(findings(intent(parameters: amount, body: body)).isEmpty)
    }

    @Test("A parameter read only by a helper function is used")
    func readInHelper() {
        let extra = "func helper() -> Int { amount }"
        #expect(findings(intent(parameters: amount, body: "_ = helper()", extra: extra)).isEmpty)
    }

    @Test("Mentioning the parameter only in parameterSummary does not count as reading it")
    func summaryOnly() {
        let extra = "static var parameterSummary: some ParameterSummary { Summary(\"Add \\(\\.$amount)\") }"
        #expect(findings(intent(parameters: amount, body: "_ = 1", extra: extra)).count == 1)
    }

    @Test("Only the unread parameter is reported")
    func oneOfTwo() {
        let two = amount + "\n    @Parameter(title: \"Note\")\n    var note: String"
        let result = findings(intent(parameters: two, body: "_ = note"))
        #expect(result.count == 1)
        #expect(result.first?.message.contains("'amount'") == true)
    }

    @Test("An intent with no perform() is left to its other rules")
    func noPerform() {
        let source = """
        struct Thing: AppIntent {
            static var title: LocalizedStringResource = "Thing"
            @Parameter(title: "Amount")
            var amount: Int
        }
        """
        #expect(findings(source).isEmpty)
    }

    @Test("A property that is not a @Parameter is not reported")
    func plainProperty() {
        #expect(findings(intent(parameters: "var cache = 0", body: "_ = 1")).isEmpty)
    }
}
