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
                    filePath: "/path/to/File.swift",
                    lineNumber: 42,
                    columnNumber: 15,
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

    @Test("A truncated run prints NOT REACHED, names the stop, and points at --continue-on-failure")
    func terminalReporterTruncatedRun() throws {
        let reporter = TerminalReporter(
            rosterSize: 45,
            truncation: RunTruncation(
                stoppedAt: "test-quality",
                unreached: (0..<37).map { "checker-\($0)" }))
        var output = ""
        let results = [
            CheckResult(checkerId: "build", status: .passed, diagnostics: [], duration: .zero),
            CheckResult(checkerId: "test-quality", status: .failed, diagnostics: [], duration: .zero),
        ]

        try reporter.report(results, to: &output)

        #expect(output.contains("FAILED (run stopped at [test-quality])"))
        #expect(output.contains("37 NOT REACHED"))
        #expect(output.contains("--continue-on-failure"))
        // The unreached are absence of information, not a narrowed selection.
        #expect(!output.contains("37 not selected"))
    }

    @Test("A truncated run is never PASSED, even when every checker that ran passed")
    func terminalReporterTruncatedButExecutedSubsetPassed() throws {
        // The shape a baseline ledger produces, and the reason this went unnoticed:
        // the runner stops at a checker that genuinely failed and records the
        // truncation, then `BaselineLedger.apply` converts that checker's errors into
        // notes and recomputes its verdict to `.passed`. Every result the reporter is
        // handed has passed, while 22 checkers never ran at all.
        let reporter = TerminalReporter(
            rosterSize: 46,
            truncation: RunTruncation(
                stoppedAt: "fallback",
                unreached: (0..<22).map { "checker-\($0)" }))
        var output = ""
        let results = [
            CheckResult(checkerId: "build", status: .passed, diagnostics: [], duration: .zero),
            CheckResult(checkerId: "fallback", status: .passed, diagnostics: [], duration: .zero),
        ]

        try reporter.report(results, to: &output)

        // A green tick over an unexamined majority is the one verdict this tool must
        // never print: 24 of 46 ran, and nothing was learned about the other 22.
        #expect(!output.contains("Quality Gate: PASSED"))
        #expect(output.contains("INCOMPLETE"))
        #expect(output.contains("fallback"))
        #expect(output.contains("22 NOT REACHED"))
    }

    @Test("Under --strict a warning run prints FAILED, matching its exit code")
    func terminalReporterStrictWarningIsFailed() throws {
        // The CLI exits 1 under --strict when any checker warned, and the summary printed
        // "✅ Quality Gate: PASSED" over it. A verdict line that disagrees with the exit
        // code is the one a human reads, so it has to carry the same rule.
        let results = [
            CheckResult(checkerId: "build", status: .passed, diagnostics: [], duration: .zero),
            CheckResult(
                checkerId: "xcode-build", status: .warning,
                diagnostics: [Diagnostic(severity: .warning, message: "unused", ruleId: "xcode-compiler")],
                duration: .zero),
        ]

        var strictOutput = ""
        try TerminalReporter(strict: true).report(results, to: &strictOutput)
        #expect(strictOutput.contains("Quality Gate: FAILED"))
        #expect(!strictOutput.contains("Quality Gate: PASSED"))
        #expect(strictOutput.contains("--strict"))

        // Without --strict a warning does not fail the run, and the line still says so.
        var defaultOutput = ""
        try TerminalReporter().report(results, to: &defaultOutput)
        #expect(defaultOutput.contains("Quality Gate: PASSED"))
    }

    @Test("Under --strict a run stopped by a warning is FAILED, not INCOMPLETE")
    func terminalReporterStrictTruncationAtWarningIsFailed() throws {
        // Under --strict the runner stops at a checker that warned. Seen in
        // BioFeedbackKit-HealthKit: a planted watchOS warning stopped the run at
        // xcode-build with 38 checkers unreached, and the summary read INCOMPLETE —
        // a verdict for "nothing failed, but not everything ran", which is not this.
        let reporter = TerminalReporter(
            rosterSize: 46,
            truncation: RunTruncation(stoppedAt: "xcode-build", unreached: (0..<38).map { "checker-\($0)" }),
            strict: true)
        var output = ""
        let results = [
            CheckResult(
                checkerId: "xcode-build", status: .warning,
                diagnostics: [Diagnostic(severity: .warning, message: "unused", ruleId: "xcode-compiler")],
                duration: .zero),
        ]
        try reporter.report(results, to: &output)
        #expect(output.contains("Quality Gate: FAILED"))
        #expect(!output.contains("INCOMPLETE"))
    }

    @Test("Under --strict the JSON summary status is failed when a checker warned")
    func jsonReporterStrictWarningIsFailed() throws {
        let results = [
            CheckResult(
                checkerId: "build", status: .warning,
                diagnostics: [Diagnostic(severity: .warning, message: "unused", ruleId: "swift-compiler")],
                duration: .zero),
        ]
        var strictOutput = ""
        try JSONReporter(strict: true).report(results, to: &strictOutput)
        #expect(strictOutput.contains("\"status\" : \"failed\""))

        var defaultOutput = ""
        try JSONReporter().report(results, to: &defaultOutput)
        #expect(defaultOutput.contains("\"status\" : \"passed\""))
    }

    @Test("Under --strict the verdict names the warning count the summary prints")
    func terminalReporterStrictGatesOnTheCountItPrints() throws {
        // A checker whose status ignores its own warning (`recursion`, and eighteen more).
        // The count line has always seen that warning; the verdict line must read the
        // same number, not the checker's status.
        let results = [
            CheckResult(
                checkerId: "recursion", status: .passed,
                diagnostics: [Diagnostic(
                    severity: .warning, message: "function 'walk(_:)' calls itself with no guard-driven base case",
                    ruleId: "recursion.unconditional-self-call")],
                duration: .zero),
        ]

        var strictOutput = ""
        try TerminalReporter(strict: true).report(results, to: &strictOutput)
        #expect(strictOutput.contains("❌ Quality Gate: FAILED (--strict: 1 warning)\n"))
        #expect(strictOutput.contains("   0 error(s), 1 warning(s)\n"))
        #expect(!strictOutput.contains("Quality Gate: PASSED"))

        var defaultOutput = ""
        try TerminalReporter().report(results, to: &defaultOutput)
        #expect(defaultOutput.contains("✅ Quality Gate: PASSED\n"))
        #expect(defaultOutput.contains("   0 error(s), 1 warning(s)\n"))
    }

    @Test("Under --strict the verdict pluralises the count it gated on")
    func terminalReporterStrictVerdictPluralises() throws {
        let warning = Diagnostic(severity: .warning, message: "unused", ruleId: "swift-compiler")
        let results = [
            CheckResult(checkerId: "build", status: .warning, diagnostics: [warning, warning], duration: .zero),
            CheckResult(checkerId: "recursion", status: .passed, diagnostics: [warning], duration: .zero),
        ]
        var output = ""
        try TerminalReporter(strict: true).report(results, to: &output)
        #expect(output.contains("❌ Quality Gate: FAILED (--strict: 3 warnings)\n"))
        #expect(output.contains("   0 error(s), 3 warning(s)\n"))
    }

    @Test("Under --strict the JSON summary gates on the warning count it reports")
    func jsonReporterStrictGatesOnTheCountItReports() throws {
        let results = [
            CheckResult(
                checkerId: "recursion", status: .passed,
                diagnostics: [Diagnostic(
                    severity: .warning, message: "function 'walk(_:)' calls itself with no guard-driven base case",
                    ruleId: "recursion.unconditional-self-call")],
                duration: .zero),
        ]
        var output = ""
        try JSONReporter(strict: true).report(results, to: &output)

        let parsed = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let summary = try #require(parsed?["summary"] as? [String: Any])
        #expect(summary["status"] as? String == "failed")
        #expect(summary["totalWarnings"] as? Int == 1)
        #expect(summary["warnings"] as? Int == 1)
        #expect(summary["passed"] as? Int == 0)
    }

    @Test("A complete narrowed run still reads as a selection, not a truncation")
    func terminalReporterNarrowedRun() throws {
        let reporter = TerminalReporter(rosterSize: 45)
        var output = ""
        let results = [
            CheckResult(checkerId: "build", status: .passed, diagnostics: [], duration: .zero)
        ]

        try reporter.report(results, to: &output)

        #expect(output.contains("1 of 45 checkers · 44 not selected"))
        #expect(!output.contains("NOT REACHED"))
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
        let data = Data(output.utf8)
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
        #expect(OutputFormat.xcode.rawValue == "xcode")
    }

    @Test("OutputFormat initializes from string")
    func outputFormatFromString() {
        #expect(OutputFormat(rawValue: "terminal") == .terminal)
        #expect(OutputFormat(rawValue: "json") == .json)
        #expect(OutputFormat(rawValue: "sarif") == .sarif)
        #expect(OutputFormat(rawValue: "xcode") == .xcode)
        #expect(OutputFormat(rawValue: "invalid") == nil)
    }

    // MARK: - Xcode Reporter Tests

    @Test("XcodeReporter emits standard Xcode diagnostic format")
    func xcodeReporterFormat() throws {
        let reporter = XcodeReporter()
        var output = ""

        try reporter.report(sampleResults, to: &output)

        #expect(output.contains("/path/to/File.swift:42:15: error: [safety] [force-unwrap] Force unwrap detected"))
    }

    @Test("XcodeReporter handles diagnostics without file path")
    func xcodeReporterNoFilePath() throws {
        let results = [
            CheckResult(
                checkerId: "build",
                status: .failed,
                diagnostics: [
                    Diagnostic(severity: .error, message: "Build failed")
                ],
                duration: .seconds(1)
            )
        ]

        let reporter = XcodeReporter()
        var output = ""

        try reporter.report(results, to: &output)

        #expect(output.contains("error: [build] Build failed"))
        #expect(!output.contains("/"))
    }

    @Test("XcodeReporter handles diagnostics without column")
    func xcodeReporterNoColumn() throws {
        let results = [
            CheckResult(
                checkerId: "safety",
                status: .failed,
                diagnostics: [
                    Diagnostic(
                        severity: .warning,
                        message: "Suspicious pattern",
                        filePath: "/src/Foo.swift",
                        lineNumber: 10
                    )
                ],
                duration: .seconds(1)
            )
        ]

        let reporter = XcodeReporter()
        var output = ""

        try reporter.report(results, to: &output)

        #expect(output.contains("/src/Foo.swift:10: warning: [safety] Suspicious pattern"))
    }

    @Test("ReporterFactory creates XcodeReporter for xcode format")
    func reporterFactoryCreatesXcodeReporter() {
        let reporter = ReporterFactory.create(for: .xcode)
        #expect(reporter is XcodeReporter)
    }
}
