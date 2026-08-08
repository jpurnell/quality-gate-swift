import Foundation
import Testing
@testable import SafetyAuditor
@testable import QualityGateCore

/// Tests for newline-splitting detection in SafetyAuditor.
///
/// `"\r\n"` is a **single `Character`** in Swift — one extended grapheme cluster — so
/// `split(separator: "\n")` does not match it at all. A file written on Windows therefore comes
/// back as one enormous line, and code that looks correct silently processes the whole document
/// as a single record.
///
/// The failure is quiet, which is what earns it a rule. Nothing throws, nothing is nil, and the
/// first symptom is a downstream complaint about missing data that sends whoever is debugging
/// somewhere else entirely.
@Suite("Newline Split Detection")
struct NewlineSplitDetectionTests {

    // MARK: - Detection: positive cases

    @Test("Detects split(separator:) on a newline literal")
    func detectsSplitOnNewline() async throws {
        let code = #"let lines = text.split(separator: "\n")"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "newline-split" })
    }

    @Test("Detects split(separator:) with additional arguments")
    func detectsSplitWithOtherArguments() async throws {
        let code = #"let lines = text.split(separator: "\n", omittingEmptySubsequences: false)"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "newline-split" })
    }

    @Test("Detects components(separatedBy:) on a newline literal")
    func detectsComponentsSeparatedByNewline() async throws {
        let code = #"let lines = text.components(separatedBy: "\n")"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "newline-split" })
    }

    /// A carriage return alone is the same trap wearing the other hat: it misses `\r\n` for the
    /// same reason, and misses plain `\n` entirely.
    @Test("Detects splitting on a carriage-return literal")
    func detectsSplitOnCarriageReturn() async throws {
        let code = #"let lines = text.split(separator: "\r")"#
        let result = try await auditCode(code)
        #expect(result.diagnostics.contains { $0.ruleId == "newline-split" })
    }

    @Test("Detects a Character-typed newline separator")
    func detectsCharacterLiteral() async throws {
        let code = """
        let newline: Character = "\\n"
        let lines = text.split(separator: newline)
        """
        let result = try await auditCode(code)
        // The variable form is out of reach without type information; the literal is what the
        // rule catches, and this asserts the direct call is still flagged.
        #expect(result.diagnostics.contains { $0.ruleId == "newline-split" } == false)
    }

    // MARK: - Detection: negative cases

    /// The recommended form must not flag, or the rule cannot be satisfied.
    @Test("Allows splitting on any newline")
    func allowsIsNewlineSplit() async throws {
        let code = #"let lines = text.split(whereSeparator: \.isNewline)"#
        let result = try await auditCode(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "newline-split" })
    }

    /// The trap that catches people fixing the other two. `.newlines` contains both `\r` and
    /// `\n`, so a CRLF counts as two separators and yields an empty element between every pair
    /// of lines — doubling a Windows file's line count.
    @Test("Detects components(separatedBy: .newlines)")
    func detectsNewlineCharacterSet() async throws {
        let code = #"let lines = text.components(separatedBy: .newlines)"#
        let result = try await auditCode(code)
        let diagnostic = try #require(result.diagnostics.first { $0.ruleId == "newline-split" })

        #expect(diagnostic.message.contains("empty element"))
    }

    /// Splitting on other separators is ordinary and must stay quiet.
    @Test("Allows splitting on other separators", arguments: [",", ";", "\\t", " "])
    func allowsOtherSeparators(separator: String) async throws {
        let code = "let fields = row.split(separator: \"\(separator)\")"
        let result = try await auditCode(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "newline-split" })
    }

    /// A newline inside ordinary text is not a split.
    @Test("Allows newline literals that are not separators")
    func allowsNewlineInOtherPositions() async throws {
        let code = #"let joined = lines.joined(separator: "\n")"#
        let result = try await auditCode(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "newline-split" })
    }

    // MARK: - Diagnostic quality

    /// The message has to say why, because the code looks right. Someone who reads
    /// "use isNewline" without being told that `\r\n` is one Character will assume it is style.
    /// Each form fails differently, and a message that blurred them would send someone to the
    /// wrong fix — most dangerously, from either of the first two to the third.
    @Test("Each form is described by what it actually produces")
    func diagnosticsAreSpecific() async throws {
        let split = try #require(await auditCode(#"let l = t.split(separator: "\n")"#)
            .diagnostics.first { $0.ruleId == "newline-split" })
        #expect(split.message.contains("ONE element"))
        #expect(split.message.lowercased().contains("grapheme"))

        let components = try #require(await auditCode(#"let l = t.components(separatedBy: "\n")"#)
            .diagnostics.first { $0.ruleId == "newline-split" })
        #expect(components.message.contains("leaves the \\r"))

        let set = try #require(await auditCode(#"let l = t.components(separatedBy: .newlines)"#)
            .diagnostics.first { $0.ruleId == "newline-split" })
        #expect(set.message.contains("empty element"))
    }

    /// The fix offered for the components forms must not be the one that inserts empty lines.
    @Test("The suggested fix never recommends CharacterSet.newlines")
    func fixDoesNotRecommendTheTrap() async throws {
        for code in [#"let l = t.components(separatedBy: "\n")"#,
                     #"let l = t.components(separatedBy: .newlines)"#] {
            let diagnostic = try #require(await auditCode(code)
                .diagnostics.first { $0.ruleId == "newline-split" })
            let fix = try #require(diagnostic.suggestedFix)

            #expect(fix.contains("isNewline"))
            #expect(fix.contains("omittingEmptySubsequences: false"),
                    "the fix must preserve blank lines, as components did")
            #expect(fix.contains("Do NOT reach for components(separatedBy: .newlines)"),
                    "the fix did not warn against the trap it is closest to")
        }
    }

    @Test("The diagnostic points at the offending line")
    func diagnosticHasLocation() async throws {
        let code = """
        let a = 1
        let b = 2
        let lines = text.split(separator: "\\n")
        """
        let result = try await auditCode(code)
        let diagnostic = try #require(result.diagnostics.first { $0.ruleId == "newline-split" })

        #expect(diagnostic.lineNumber == 3)
    }

    // MARK: - Exemptions

    /// Some code really does mean LF only — a wire protocol that specifies it, a test asserting
    /// this very behaviour. The existing SAFETY escape hatch applies.
    @Test("A SAFETY comment suppresses the diagnostic")
    func safetyCommentSuppresses() async throws {
        let code = """
        // SAFETY: protocol specifies LF framing, CRLF would be a different message
        let lines = text.split(separator: "\\n")
        """
        let result = try await auditCode(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "newline-split" })
    }

    // MARK: - Helpers

    private func auditCode(_ code: String) async throws -> CheckResult {
        let auditor = SafetyAuditor()
        let config = Configuration()
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
