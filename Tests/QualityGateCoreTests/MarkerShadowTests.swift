import Foundation
import Testing
@testable import QualityGateCore

/// What a marker silenced is found by analysing the file without it.
@Suite("MarkerShadow")
struct MarkerShadowTests {

    private func finding(_ rule: String, line: Int) -> Diagnostic {
        Diagnostic(severity: .warning, message: "m \(rule)", filePath: "/repo/A.swift", lineNumber: line, columnNumber: 1, ruleId: rule)
    }

    @Test("Neutralising keeps every line and column where it was")
    func neutralisedKeepsLayout() {
        let source = "let a = 1 // lifecycle:exempt — reason\nlet b = 2\n"
        let shadow = MarkerShadow.neutralised(source, markers: ["lifecycle:exempt"])
        #expect(shadow == "let a = 1 // ________________ — reason\nlet b = 2\n")
        #expect(shadow?.count == source.count)
    }

    @Test("A file without the marker has no shadow, so it is not analysed twice")
    func noMarkerNoShadow() {
        #expect(MarkerShadow.neutralised("let a = 1\n", markers: ["lifecycle:exempt"]) == nil)
        #expect(MarkerShadow.neutralised("let a = 1\n", markers: [""]) == nil)
    }

    @Test("A finding only the shadow run raises is recorded against the nearest marker")
    func silencedFindingIsRecorded() {
        let lines = [
            "final class Model {",
            "    private var task: Task<Void, Never>? // lifecycle:exempt — captures [weak self], self-terminates on dealloc",
            "}",
        ]
        let records = MarkerShadow.silenced(
            real: [finding("lifecycle.other", line: 1)],
            shadow: [finding("lifecycle.other", line: 1), finding("lifecycle-task-no-deinit", line: 2)],
            form: "lifecycle:exempt", sourceLines: lines, filePath: "/repo/A.swift"
        ).map(SuppressionRecord.init)

        #expect(records.count == 1)
        #expect(records[0].ruleId == "lifecycle-task-no-deinit")
        #expect(records[0].lineNumber == 2)
        #expect(records[0].markerLine == 2)
        #expect(records[0].reason == "captures [weak self], self-terminates on dealloc")
        #expect(records[0].kind == .suppressed)
        #expect(records[0].rejection == "6 words, 8 required")
        #expect(records[0].forwardedToCorpus == false)
    }

    @Test("A marker that silences nothing produces no record")
    func decorativeMarkerProducesNothing() {
        let same = [finding("r", line: 4)]
        #expect(MarkerShadow.silenced(
            real: same, shadow: same, form: "lifecycle:exempt",
            sourceLines: ["// lifecycle:exempt"], filePath: "/repo/A.swift").isEmpty)
    }

    @Test("Two identical findings, one silenced, record one")
    func multisetDifference() {
        let records = MarkerShadow.silenced(
            real: [finding("r", line: 4)],
            shadow: [finding("r", line: 4), finding("r", line: 4)],
            form: "x:exempt", sourceLines: ["", "", "", "code // x:exempt"], filePath: "/repo/A.swift")
        #expect(records.count == 1)
    }

    @Test("A marker out of reach is still a record, with no marker line and no reason")
    func markerOutOfReach() {
        let records = MarkerShadow.silenced(
            real: [], shadow: [finding("r", line: 5)], form: "x:exempt",
            sourceLines: ["// x:exempt because", "", "", "", "code"], filePath: "/repo/A.swift"
        ).map(SuppressionRecord.init)
        #expect(records.count == 1)
        #expect(records[0].markerLine == nil)
        #expect(records[0].rejection == "no reason given")
    }
}
