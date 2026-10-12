import Foundation
import Testing
@testable import QualityGateCore

/// The summary says how much the run was told not to raise, in both formats a person reads.
@Suite("Suppression totals in the reports")
struct SuppressionReportingTests {

    private static let longReason = "the cache directory may not exist yet and a miss is the ordinary case"

    private var results: [CheckResult] {
        [
            CheckResult(
                checkerId: "logging", status: .passed, diagnostics: [],
                overrides: [
                    .inlineMarker(
                        form: "// silent:", ruleId: "logging.silent-try", filePath: "/repo/A.swift",
                        findingLine: 3, markerLine: 3, comment: "try? f() // silent: best effort"),
                    .inlineMarker(
                        form: "// silent:", ruleId: "logging.silent-try", filePath: "/repo/A.swift",
                        findingLine: 9, markerLine: 8, comment: "// silent: \(Self.longReason)"),
                    .inlineMarker(
                        form: "// logging:", ruleId: "logging.print-statement", filePath: "/repo/B.swift",
                        findingLine: 4, markerLine: 4, comment: "print(x) // logging: cli"),
                ],
                duration: .zero),
            CheckResult(
                checkerId: "fp-safety", status: .passed,
                diagnostics: [
                    Diagnostic(
                        severity: .note, message: "x (baselined until 2027-01-01)",
                        filePath: "/repo/C.swift", lineNumber: 5, ruleId: "fp-division-unguarded",
                        origin: BaselineLedger.origin)
                ],
                duration: .zero),
            CheckResult(checkerId: "recursion", status: .passed, diagnostics: [], duration: .zero),
        ]
    }

    private var exclusions: [ActiveExclusion] {
        [
            ActiveExclusion(
                form: "excludePatterns", entries: ["**/Fixtures/**"], matchedFiles: 14,
                detail: "1 pattern matched 14 .swift file(s); they were not audited")
        ]
    }

    // MARK: - Terminal

    @Test("The terminal summary prints the totals, by form and by checker, and the exclusions")
    func terminalSummary() throws {
        var output = ""
        try TerminalReporter(exclusions: exclusions).report(results, to: &output)

        let expected = """
               Silenced findings: 1 acknowledged (reason validated) · 2 suppressed (not validated) · 1 baselined
                 suppressed by form: // logging: 1 · // silent: 1
                 acknowledged by form: // silent: 1
                 by checker: logging 1 acknowledged, 2 suppressed · fp-safety 1 baselined
                 ℹ️  note: 2 suppressed finding(s) do not gate (suppressions: note). Set `suppressions: warn` in .quality-gate.yml to gate on them; --format json lists each one.
               Exclusions in force (what they hid is not measured):
                 excludePatterns — 1 pattern matched 14 .swift file(s); they were not audited

            """
        #expect(output.contains(expected))
    }

    @Test("A run that silenced nothing prints no suppression lines at all")
    func terminalQuietWhenEmpty() throws {
        var output = ""
        try TerminalReporter().report(
            [CheckResult(checkerId: "recursion", status: .passed, diagnostics: [], duration: .zero)],
            to: &output)
        #expect(!output.contains("Silenced findings"))
        #expect(!output.contains("Exclusions in force"))
    }

    @Test("Under a gating policy the note says the suppressions gate, and does not advertise the key")
    func terminalUnderRatchet() throws {
        var output = ""
        try TerminalReporter(suppressionPolicy: .warn).report(results, to: &output)
        #expect(output.contains("     ℹ️  note: 2 suppressed finding(s) are reported as gate.unvalidated-suppression (suppressions: warn).\n"))
        #expect(!output.contains("Set `suppressions: warn`"))
    }

    // MARK: - JSON

    private func json(_ reporter: JSONReporter) throws -> [String: Any] {
        var output = ""
        try reporter.report(results, to: &output)
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
        return try #require(object as? [String: Any])
    }

    @Test("The JSON summary carries overall totals, per-checker totals, the policy and exclusions")
    func jsonSummary() throws {
        let report = try json(JSONReporter(exclusions: exclusions))
        let summary = try #require(report["summary"] as? [String: Any])
        let suppressions = try #require(summary["suppressions"] as? [String: Any])

        #expect(suppressions["acknowledged"] as? Int == 1)
        #expect(suppressions["suppressed"] as? Int == 2)
        #expect(suppressions["baselined"] as? Int == 1)
        #expect(suppressions["policy"] as? String == "note")
        #expect(suppressions["suppressedByForm"] as? [String: Int] == ["// silent:": 1, "// logging:": 1])
        #expect(suppressions["acknowledgedByForm"] as? [String: Int] == ["// silent:": 1])

        let byChecker = try #require(suppressions["byChecker"] as? [String: [String: Any]])
        #expect(Set(byChecker.keys) == ["logging", "fp-safety", "recursion"])
        #expect(byChecker["logging"]?["suppressed"] as? Int == 2)
        #expect(byChecker["logging"]?["acknowledged"] as? Int == 1)
        #expect(byChecker["fp-safety"]?["baselined"] as? Int == 1)
        #expect(byChecker["recursion"]?["suppressed"] as? Int == 0)

        let listed = try #require(suppressions["exclusions"] as? [[String: Any]])
        #expect(listed.count == 1)
        #expect(listed[0]["form"] as? String == "excludePatterns")
        #expect(listed[0]["matchedFiles"] as? Int == 14)
        #expect(listed[0]["entries"] as? [String] == ["**/Fixtures/**"])
    }

    @Test("Each JSON result lists its records with kind, form, both lines and the reason")
    func jsonRecords() throws {
        let report = try json(JSONReporter())
        let listed = try #require(report["results"] as? [[String: Any]])
        #expect(listed.count == 3)

        // The published fields are still there, untouched.
        #expect(listed[0]["checkerId"] as? String == "logging")
        #expect((listed[0]["overrides"] as? [[String: Any]])?.count == 3)

        let records = try #require(listed[0]["suppressions"] as? [[String: Any]])
        #expect(records.count == 3)
        #expect(records[0]["kind"] as? String == "suppressed")
        #expect(records[0]["form"] as? String == "// silent:")
        #expect(records[0]["ruleId"] as? String == "logging.silent-try")
        #expect(records[0]["filePath"] as? String == "/repo/A.swift")
        #expect(records[0]["lineNumber"] as? Int == 3)
        #expect(records[0]["markerLine"] as? Int == 3)
        #expect(records[0]["reason"] as? String == "best effort")
        #expect(records[0]["rejection"] as? String == "2 words, 8 required")
        #expect(records[0]["validator"] == nil)

        #expect(records[1]["kind"] as? String == "acknowledged")
        #expect(records[1]["validator"] as? String == "reason-quality")
        #expect(records[1]["lineNumber"] as? Int == 9)
        #expect(records[1]["markerLine"] as? Int == 8)

        let totals = try #require(listed[0]["suppressionTotals"] as? [String: Any])
        #expect(totals["suppressed"] as? Int == 2)
        #expect(totals["acknowledged"] as? Int == 1)

        #expect((listed[2]["suppressions"] as? [[String: Any]])?.isEmpty == true)
    }
}
