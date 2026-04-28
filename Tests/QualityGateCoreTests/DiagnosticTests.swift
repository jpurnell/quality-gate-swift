import Foundation
import Testing
@testable import QualityGateCore

/// Tests for the Diagnostic model.
///
/// These tests verify the core diagnostic reporting structure used by all checkers.
@Suite("Diagnostic Model Tests")
struct DiagnosticTests {

    // MARK: - Initialization Tests

    @Test("Diagnostic initializes with all properties")
    func initializesWithAllProperties() {
        let diagnostic = Diagnostic(
            severity: .error,
            message: "Force unwrap detected",
            file: "/path/to/File.swift",
            line: 42,
            column: 15,
            ruleId: "force-unwrap",
            suggestedFix: "Use optional binding instead"
        )

        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message == "Force unwrap detected")
        #expect(diagnostic.file == "/path/to/File.swift")
        #expect(diagnostic.line == 42)
        #expect(diagnostic.column == 15)
        #expect(diagnostic.ruleId == "force-unwrap")
        #expect(diagnostic.suggestedFix == "Use optional binding instead")
    }

    @Test("Diagnostic initializes with minimal properties")
    func initializesWithMinimalProperties() {
        let diagnostic = Diagnostic(
            severity: .warning,
            message: "Consider refactoring"
        )

        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.message == "Consider refactoring")
        #expect(diagnostic.file == nil)
        #expect(diagnostic.line == nil)
        #expect(diagnostic.column == nil)
        #expect(diagnostic.ruleId == nil)
        #expect(diagnostic.suggestedFix == nil)
    }

    // MARK: - Severity Tests

    @Test("Severity has correct raw values for serialization")
    func severityRawValues() {
        #expect(Diagnostic.Severity.error.rawValue == "error")
        #expect(Diagnostic.Severity.warning.rawValue == "warning")
        #expect(Diagnostic.Severity.note.rawValue == "note")
    }

    @Test("Severity is Comparable with correct ordering")
    func severityComparison() {
        #expect(Diagnostic.Severity.error > Diagnostic.Severity.warning)
        #expect(Diagnostic.Severity.warning > Diagnostic.Severity.note)
        #expect(Diagnostic.Severity.error > Diagnostic.Severity.note)
    }

    // MARK: - Codable Tests

    @Test("Diagnostic encodes to JSON correctly")
    func encodesToJSON() throws {
        let diagnostic = Diagnostic(
            severity: .error,
            message: "Test error",
            file: "/test.swift",
            line: 10,
            column: 5,
            ruleId: "test-rule",
            suggestedFix: "Fix it"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(diagnostic)
        let json = String(data: data, encoding: .utf8)

        #expect(json != nil)
        #expect(json?.contains("\"severity\":\"error\"") == true)
        #expect(json?.contains("\"message\":\"Test error\"") == true)
        #expect(json?.contains("\"lineNumber\":10") == true)
    }

    @Test("Diagnostic decodes from JSON correctly")
    func decodesFromJSON() throws {
        let json = """
        {
            "severity": "warning",
            "message": "Test warning",
            "file": "/path.swift",
            "line": 20,
            "column": 8,
            "ruleId": "test-rule",
            "suggestedFix": null
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let diagnostic = try decoder.decode(Diagnostic.self, from: data)

        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.message == "Test warning")
        #expect(diagnostic.file == "/path.swift")
        #expect(diagnostic.line == 20)
        #expect(diagnostic.column == 8)
        #expect(diagnostic.ruleId == "test-rule")
        #expect(diagnostic.suggestedFix == nil)
    }

    // MARK: - Sendable Compliance

    @Test("Diagnostic is Sendable")
    func isSendable() async {
        let diagnostic = Diagnostic(severity: .error, message: "Test")

        // Pass across concurrency boundary to verify Sendable
        let result = await Task {
            diagnostic.message
        }.value

        #expect(result == "Test")
    }
}
