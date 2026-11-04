import Foundation
import Testing
@testable import AppIntentsAuditor
import QualityGateCore

/// An intent may decline a surface — Siri, Shortcuts or MCP — but the decision is recorded with
/// its reason, never silent. `// appintents:exempt <surface> — <reason>` follows the gate's
/// existing marker convention (`stochastic:exempt`): a marker with no reason does not count.
@Suite("AppIntentVisitor — exposure exemptions")
struct ExposureExemptionTests {

    private let reason = "this action rewrites the user's ledger and must only run from inside the app"

    private func source(marker: String?, placement: Placement = .above, extraAttribute: Bool = false) -> String {
        let attribute = extraAttribute ? "@MainActor\n" : ""
        let above = placement == .above ? (marker.map { "\($0)\n" } ?? "") : ""
        let trailing = placement == .sameLine ? (marker.map { " \($0)" } ?? "") : ""
        return """
        import AppIntents

        \(above)\(attribute)struct Ledger: AppIntent {\(trailing)
            static var title: LocalizedStringResource = "Rewrite Ledger"
            static var description: IntentDescription = "Rewrites the ledger"
            func perform() async throws -> some IntentResult { .result() }
        }
        """
    }

    private enum Placement { case above, sameLine }

    private func run(_ source: String) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        AppIntentVisitor.analyzeWithOverrides(source: source, fileName: "T.swift")
    }

    @Test("Without a marker the route is still asked for")
    func baseline() {
        #expect(run(source(marker: nil)).diagnostics.contains { $0.ruleId == "appintent-no-assistant-schema" })
    }

    @Test("A reasoned siri exemption silences the finding and is recorded")
    func reasonedExemption() throws {
        let result = run(source(marker: "// appintents:exempt siri — \(reason)"))
        #expect(!result.diagnostics.contains { $0.ruleId == "appintent-no-assistant-schema" })
        let recorded = try #require(result.overrides.first)
        #expect(recorded.ruleId == "appintent-no-assistant-schema")
        #expect(result.overrides.count == 1)
    }

    @Test("A trailing marker on the declaration line counts")
    func sameLine() {
        let result = run(source(marker: "// appintents:exempt siri — \(reason)", placement: .sameLine))
        #expect(!result.diagnostics.contains { $0.ruleId == "appintent-no-assistant-schema" })
    }

    @Test("A marker above the attributes counts")
    func aboveAttributes() {
        let result = run(source(marker: "// appintents:exempt siri — \(reason)", extraAttribute: true))
        #expect(!result.diagnostics.contains { $0.ruleId == "appintent-no-assistant-schema" })
    }

    @Test("A marker with no reason does not count, and is itself reported")
    func bareMarker() throws {
        let result = run(source(marker: "// appintents:exempt siri"))
        #expect(result.diagnostics.contains { $0.ruleId == "appintent-no-assistant-schema" })
        let bare = try #require(result.diagnostics.first { $0.ruleId == "appintent.exempt-no-justification" })
        #expect(bare.severity == .warning)
        #expect(result.overrides.isEmpty)
    }

    @Test("Punctuation is not a reason")
    func punctuationOnly() {
        let result = run(source(marker: "// appintents:exempt siri —"))
        #expect(result.diagnostics.contains { $0.ruleId == "appintent.exempt-no-justification" })
    }

    @Test("An unknown surface is reported and exempts nothing")
    func unknownSurface() throws {
        let result = run(source(marker: "// appintents:exempt sirii — \(reason)"))
        #expect(result.diagnostics.contains { $0.ruleId == "appintent-no-assistant-schema" })
        let unknown = try #require(result.diagnostics.first { $0.ruleId == "appintent.exempt-unknown-surface" })
        #expect(unknown.message.contains("sirii"))
        #expect(result.overrides.isEmpty)
    }

    @Test("Declining one surface does not decline another",
          arguments: ["shortcuts", "mcp"])
    func otherSurfaceDoesNotCover(surface: String) {
        let result = run(source(marker: "// appintents:exempt \(surface) — \(reason)"))
        #expect(result.diagnostics.contains { $0.ruleId == "appintent-no-assistant-schema" })
        #expect(!result.diagnostics.contains { $0.ruleId == "appintent.exempt-unknown-surface" },
                "shortcuts and mcp are valid surfaces, they just do not cover the Siri rule")
    }

    @Test("analyze still returns diagnostics only, as before")
    func analyzeUnchanged() {
        let diagnostics = AppIntentVisitor.analyze(source: source(marker: nil), fileName: "T.swift")
        #expect(diagnostics.contains { $0.ruleId == "appintent-no-assistant-schema" })
    }
}
