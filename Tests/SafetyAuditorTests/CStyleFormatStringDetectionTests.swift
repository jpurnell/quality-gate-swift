import Foundation
import Testing
@testable import SafetyAuditor
@testable import QualityGateCore

/// Tests for C-style format string detection in SafetyAuditor.
///
/// Enforces the rule in development-guidelines/00_CORE_RULES/01_CODING_RULES.md §3.7
/// that forbids `String(format:)` and related C-printf-bridged APIs because they
/// crash at runtime (SIGSEGV) when given e.g. `%s` with a Swift String.
@Suite("C-Style Format String Detection")
struct CStyleFormatStringDetectionTests {

    // MARK: - Detection: positive cases

    @Test("Detects String(format:) with single string argument")
    func detectsStringFormatBasic() async throws {
        let code = #"let s = String(format: "hello")"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "c-style-format-string" })
    }

    @Test("Detects String(format:) with multiple arguments")
    func detectsStringFormatMultiArg() async throws {
        let code = #"let s = String(format: "%@ %@", a, b)"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "c-style-format-string" })
    }

    @Test("Detects String(format:) with locale parameter")
    func detectsStringFormatWithLocale() async throws {
        let code = #"let s = String(format: "%.3f", locale: Locale.current, value)"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "c-style-format-string" })
    }

    @Test("Detects String(format:) with locale and arguments parameters")
    func detectsStringFormatWithVarArgs() async throws {
        let code = #"let s = String(format: "%@", locale: Locale.current, arguments: args)"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "c-style-format-string" })
    }

    @Test("Detects NSString(format:) constructor")
    func detectsNSStringFormat() async throws {
        let code = #"let s = NSString(format: "%@", value)"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "c-style-format-string" })
    }

    @Test("Detects NSString.localizedStringWithFormat(_:_:)")
    func detectsLocalizedStringWithFormat() async throws {
        let code = #"let s = NSString.localizedStringWithFormat("%@", value)"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "c-style-format-string" })
    }

    // MARK: - Detection: negative cases (no false positives)

    @Test("Does NOT flag String(format:) inside a string literal")
    func doesNotFlagInsideStringLiteral() async throws {
        let code = #"let s = "this calls String(format: \"%@\", x) somewhere""#
        let result = try await auditCode(code)
        #expect(result.diagnostics.filter { $0.ruleId == "c-style-format-string" }.isEmpty)
    }

    @Test("Does NOT flag String(format:) inside a doc comment")
    func doesNotFlagInsideDocComment() async throws {
        let code = """
        /// Example: String(format: "%@", x)
        func foo() {}
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.filter { $0.ruleId == "c-style-format-string" }.isEmpty)
    }

    @Test("Does NOT flag String(format:) inside a multi-line string")
    func doesNotFlagInsideMultiLineString() async throws {
        let code = "let s = \"\"\"\nString(format: \"%@\", x)\n\"\"\"\n"
        let result = try await auditCode(code)
        #expect(result.diagnostics.filter { $0.ruleId == "c-style-format-string" }.isEmpty)
    }

    @Test("Does NOT flag String(format:) on a line marked // SAFETY:")
    func honorsSafetyExemption() async throws {
        let code = #"let s = String(format: "%@", x) // SAFETY: legacy, removing in #123"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.filter { $0.ruleId == "c-style-format-string" }.isEmpty)
    }

    @Test("Does NOT flag String.padding(toLength:withPad:startingAt:)")
    func doesNotFlagStringPadding() async throws {
        let code = #"let s = "hi".padding(toLength: 30, withPad: " ", startingAt: 0)"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.filter { $0.ruleId == "c-style-format-string" }.isEmpty)
    }

    @Test("Does NOT flag value.formatted()")
    func doesNotFlagFormattedExtension() async throws {
        let code = "let s = value.formatted()"
        let result = try await auditCode(code)
        #expect(result.diagnostics.filter { $0.ruleId == "c-style-format-string" }.isEmpty)
    }

    @Test("Does NOT flag DateFormatter.string(from:)")
    func doesNotFlagDateFormatter() async throws {
        let code = "let s = formatter.string(from: date)"
        let result = try await auditCode(code)
        #expect(result.diagnostics.filter { $0.ruleId == "c-style-format-string" }.isEmpty)
    }

    // MARK: - Diagnostic shape

    @Test("Diagnostic has severity .error")
    func diagnosticSeverityIsError() async throws {
        let code = #"let s = String(format: "%@", x)"#
        let result = try await auditCode(code)
        let d = result.diagnostics.first { $0.ruleId == "c-style-format-string" }
        #expect(d?.severity == .error)
    }

    @Test("Diagnostic ruleId is c-style-format-string")
    func diagnosticRuleId() async throws {
        let code = #"let s = String(format: "%@", x)"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "c-style-format-string" })
    }

    @Test("Diagnostic suggestedFix points at the coding rules document")
    func diagnosticSuggestedFixCitation() async throws {
        let code = #"let s = String(format: "%@", x)"#
        let result = try await auditCode(code)
        let d = result.diagnostics.first { $0.ruleId == "c-style-format-string" }
        #expect(d?.suggestedFix?.contains("01_CODING_RULES.md") == true)
    }

    @Test("Multiple violations in one file produce multiple diagnostics")
    func multipleViolationsProduceMultipleDiagnostics() async throws {
        let code = """
        let a = String(format: "%@", x)
        let b = String(format: "%.3f", y)
        let c = NSString(format: "%@", z)
        """
        let result = try await auditCode(code)
        #expect(result.diagnostics.filter { $0.ruleId == "c-style-format-string" }.count == 3)
    }

    @Test("Reports correct line number for the violation")
    func reportsCorrectLineNumber() async throws {
        let code = """
        let a = 1
        let b = 2
        let c = String(format: "%@", x)
        """
        let result = try await auditCode(code)
        let d = result.diagnostics.first { $0.ruleId == "c-style-format-string" }
        #expect(d?.lineNumber == 3)
    }

    // MARK: - Regression fixture

    @Test("Regression: BioFeedbackKit playground %s + Swift String crash")
    func regressionBioFeedbackPlayground() async throws {
        let source = """
            let label = "test"
            let line = String(format: "%s passed", label)
            """
        let result = try await auditCode(source)
        let matches = result.diagnostics.filter { $0.ruleId == "c-style-format-string" }
        #expect(matches.count == 1)
    }

    // MARK: - Helper

    private func auditCode(_ code: String) async throws -> CheckResult {
        let auditor = SafetyAuditor()
        let config = Configuration()
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
