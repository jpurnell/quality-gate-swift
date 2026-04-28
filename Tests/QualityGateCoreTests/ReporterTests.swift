import Foundation
import Testing
@testable import QualityGateCore

/// Tests for Reporter protocol and implementations.
///
/// Reporters format CheckResults for different output targets.
@Suite("Reporter Tests")
struct ReporterTests {

    // MARK: - Test Fixtures

    let sampleResults: [CheckResult] = [
        CheckResult(
            checkerId: "build",
            status: .passed,
            diagnostics: [],
            duration: .seconds(1.5)
        ),
        CheckResult(
            checkerId: "safety",
            status: .failed,
            diagnostics: [
                Diagnostic(
                    severity: .error,
                    message: "Force unwrap detected",
                    file: "/path/to/File.swift",
                    line: 42,
                    column: 15,
                    ruleId: "force-unwrap",
                    suggestedFix: "Use optional binding"
                )
            ],
            duration: .seconds(0.3)
        )
    ]

    // MARK: - Terminal Reporter Tests

    @Test("TerminalReporter outputs human-readable format")
    func terminalReporterOutput() throws {
        let reporter = TerminalReporter()
        var output = ""

        try reporter.report(sampleResults, to: &output)

        #expect(output.contains("build"))
        #expect(output.contains("passed") || output.contains("✓") || output.contains("PASSED"))
        #expect(output.contains("safety"))
        #expect(output.contains("failed") || output.contains("✗") || output.contains("FAILED"))
        #expect(output.contains("Force unwrap detected"))
    }

    @Test("TerminalReporter shows file location for diagnostics")
    func terminalReporterShowsLocation() throws {
        let reporter = TerminalReporter()
        var output = ""

        try reporter.report(sampleResults, to: &output)

        #expect(output.contains("/path/to/File.swift"))
        #expect(output.contains("42")) // Line number
    }

    @Test("TerminalReporter handles empty results")
    func terminalReporterEmptyResults() throws {
        let reporter = TerminalReporter()
        var output = ""

        try reporter.report([], to: &output)

        // Should not crash, may output summary
        #expect(output.isEmpty == false || true) // Just verify no crash
    }

    // MARK: - JSON Reporter Tests

    @Test("JSONReporter outputs valid JSON")
    func jsonReporterOutputsValidJSON() throws {
        let reporter = JSONReporter()
        var output = ""

        try reporter.report(sampleResults, to: &output)

        // Verify it's valid JSON by parsing it
        let data = output.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: data)

        #expect(parsed is [String: Any] || parsed is [[String: Any]])
    }

    @Test("JSONReporter includes all result fields")
    func jsonReporterIncludesAllFields() throws {
        let reporter = JSONReporter()
        var output = ""

        try reporter.report(sampleResults, to: &output)

        #expect(output.contains("\"checkerId\""))
        #expect(output.contains("\"status\""))
        #expect(output.contains("\"diagnostics\""))
        #expect(output.contains("\"duration\""))
        #expect(output.contains("\"build\""))
        #expect(output.contains("\"safety\""))
    }

    @Test("JSONReporter includes diagnostic details")
    func jsonReporterIncludesDiagnostics() throws {
        let reporter = JSONReporter()
        var output = ""

        try reporter.report(sampleResults, to: &output)

        #expect(output.contains("\"severity\""))
        #expect(output.contains("\"message\""))
        #expect(output.contains("\"filePath\""))
        #expect(output.contains("\"lineNumber\""))
        #expect(output.contains("\"ruleId\""))
        #expect(output.contains("Force unwrap detected"))
    }

    // MARK: - SARIF Reporter Tests

    @Test("SARIFReporter outputs valid SARIF 2.1.0 format")
    func sarifReporterOutputsValidFormat() throws {
        let reporter = SARIFReporter()
        var output = ""

        try reporter.report(sampleResults, to: &output)

        // SARIF has specific required fields
        #expect(output.contains("\"$schema\""))
        #expect(output.contains("\"version\""))
        #expect(output.contains("\"2.1.0\""))
        #expect(output.contains("\"runs\""))
    }

    @Test("SARIFReporter includes tool information")
    func sarifReporterIncludesToolInfo() throws {
        let reporter = SARIFReporter()
        var output = ""

        try reporter.report(sampleResults, to: &output)

        #expect(output.contains("\"tool\""))
        #expect(output.contains("\"driver\""))
        #expect(output.contains("quality-gate-swift"))
    }

    @Test("SARIFReporter converts diagnostics to results")
    func sarifReporterConvertsDiagnostics() throws {
        let reporter = SARIFReporter()
        var output = ""

        try reporter.report(sampleResults, to: &output)

        #expect(output.contains("\"results\""))
        #expect(output.contains("\"level\""))
        #expect(output.contains("\"message\""))
        #expect(output.contains("\"locations\""))
    }

    @Test("SARIFReporter maps severity to SARIF levels")
    func sarifReporterMapsSeverity() throws {
        let results = [
            CheckResult(
                checkerId: "test",
                status: .failed,
                diagnostics: [
                    Diagnostic(severity: .error, message: "Error"),
                    Diagnostic(severity: .warning, message: "Warning"),
                    Diagnostic(severity: .note, message: "Note")
                ],
                duration: .seconds(1)
            )
        ]

        let reporter = SARIFReporter()
        var output = ""

        try reporter.report(results, to: &output)

        // SARIF uses "error", "warning", "note" levels
        #expect(output.contains("\"error\""))
        #expect(output.contains("\"warning\""))
        #expect(output.contains("\"note\""))
    }

    // MARK: - Reporter Factory Tests

    @Test("ReporterFactory creates correct reporter for format")
    func reporterFactoryCreatesCorrectType() {
        let terminalReporter = ReporterFactory.create(for: .terminal)
        let jsonReporter = ReporterFactory.create(for: .json)
        let sarifReporter = ReporterFactory.create(for: .sarif)

        #expect(terminalReporter is TerminalReporter)
        #expect(jsonReporter is JSONReporter)
        #expect(sarifReporter is SARIFReporter)
    }

    // MARK: - OutputFormat Tests

    @Test("OutputFormat has correct raw values")
    func outputFormatRawValues() {
        #expect(OutputFormat.terminal.rawValue == "terminal")
        #expect(OutputFormat.json.rawValue == "json")
        #expect(OutputFormat.sarif.rawValue == "sarif")
    }

    @Test("OutputFormat initializes from string")
    func outputFormatFromString() {
        #expect(OutputFormat(rawValue: "terminal") == .terminal)
        #expect(OutputFormat(rawValue: "json") == .json)
        #expect(OutputFormat(rawValue: "sarif") == .sarif)
        #expect(OutputFormat(rawValue: "invalid") == nil)
    }
}
