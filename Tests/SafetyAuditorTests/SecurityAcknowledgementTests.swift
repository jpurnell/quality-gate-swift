import Foundation
import Testing
@testable import SafetyAuditor
@testable import QualityGateCore

/// An acknowledgement is a record.
///
/// A `// SECURITY:` comment used to silence any security finding on its line or the next, with
/// no reason and — for nine of ten rules — no trace in any report. These tests hold every rule
/// to the same contract: a reason that passes `JustificationValidator` is recorded as an
/// override; anything less leaves the finding standing and says why the marker failed; and a
/// marker written for a different auditor does not reach security rules at all.
///
/// See `quality-gate-swift-project/plans/proposals/AnAcknowledgementIsARecord.md`.
@Suite("Security acknowledgements")
struct SecurityAcknowledgementTests {

    /// One fixture per shipped rule, each producing exactly one finding of that rule.
    static let fixtures: [(rule: String, code: String)] = [
        ("security.hardcoded-secret", #"let apiKey = "sk-abc123""#),
        ("security.insecure-transport", #"let endpoint = "http://example.com/api""#),
        ("security.weak-crypto", "let digest = Insecure.MD5.hash(data: payload)"),
        ("security.eval-js", "webView.evaluateJavaScript(script)"),
        ("security.sql-injection", #"try db.execute("SELECT * FROM t WHERE id = \(id)")"#),
        ("security.insecure-keychain", "let level = Security.kSecAttrAccessibleAlways"),
        ("security.tls-disabled", "config.allowsExpiredCertificates = true"),
        ("security.path-traversal", "let data = FileManager.default.contents(atPath: base.appendingPathComponent(name).path)"),
        ("security.ssrf", "let target = URL(string: input)"),
        ("security.command-injection", """
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "grep \\(pattern) \\(file)"]
            """),
    ]

    static let ruleIds = fixtures.map(\.rule)

    private static let validReason =
        "// SECURITY: fixture input is a compile-time constant and never reaches a user"

    private func audit(_ code: String) async throws -> CheckResult {
        try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: Configuration())
    }

    /// The fixture with `marker` on the line above its last line — the line the finding is on.
    private func marked(_ code: String, with marker: String) -> String {
        var lines = code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        lines.insert(marker, at: lines.count - 1)
        return lines.joined(separator: "\n")
    }

    private func fixture(_ rule: String) throws -> String {
        try #require(Self.fixtures.first { $0.rule == rule }).code
    }

    // MARK: - The baseline every other test depends on

    @Test("Each fixture produces its rule's finding", arguments: ruleIds)
    func fixtureFires(rule: String) async throws {
        let result = try await audit(try fixture(rule))
        #expect(result.diagnostics.contains { $0.ruleId == rule }, "fixture for \(rule) found nothing")
    }

    // MARK: - Accepted

    @Test("A reasoned acknowledgement is recorded, not reported", arguments: ruleIds)
    func reasonedAcknowledgementIsRecorded(rule: String) async throws {
        let code = marked(try fixture(rule), with: Self.validReason)
        let result = try await audit(code)
        // The finding is on the fixture's last line, which the marker pushed down by one.
        let findingLine = code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count

        #expect(!result.diagnostics.contains { $0.ruleId == rule })
        let override = try #require(result.overrides.first { $0.ruleId == rule },
                                    "\(rule) was silenced with no record of it")
        #expect(override.filePath == "test.swift")
        #expect(override.lineNumber == findingLine)
        #expect(override.justification.contains("compile-time constant"))
        #expect(!override.justification.contains("// SECURITY:"), "the marker is not the reason")
    }

    @Test("The same reason at two sites is accepted twice")
    func repeatedReasonIsAccepted() async throws {
        let code = """
            \(Self.validReason)
            let first = URL(string: input)
            \(Self.validReason)
            let second = URL(string: other)
            """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.ssrf" })
        #expect(result.overrides.filter { $0.ruleId == "security.ssrf" }.count == 2)
    }

    // MARK: - Rejected

    @Test("A short reason leaves the finding standing and says why", arguments: ruleIds)
    func shortReasonIsRejected(rule: String) async throws {
        let result = try await audit(marked(try fixture(rule), with: "// SECURITY: standardized above"))

        let finding = try #require(result.diagnostics.first { $0.ruleId == rule },
                                   "\(rule) accepted a two-word reason")
        #expect(finding.message.contains("not accepted"))
        #expect(finding.message.contains("2 words"))
        #expect(!result.overrides.contains { $0.ruleId == rule })
    }

    @Test("A bare marker is no acknowledgement", arguments: ruleIds)
    func bareMarkerIsRejected(rule: String) async throws {
        let result = try await audit(marked(try fixture(rule), with: "// SECURITY:"))
        #expect(result.diagnostics.contains { $0.ruleId == rule })
        #expect(!result.overrides.contains { $0.ruleId == rule })
    }

    @Test("A generic phrase is no reason")
    func genericReasonIsRejected() async throws {
        let result = try await audit(marked(try fixture("security.ssrf"), with: "// SECURITY: safe"))
        let finding = try #require(result.diagnostics.first { $0.ruleId == "security.ssrf" })
        #expect(finding.message.contains("generic"))
    }

    /// A rejected acknowledgement keeps the rule's own severity: the marker failing is not a
    /// reason to treat the finding as less — or more — serious than it is.
    @Test("Rejection keeps the rule's severity")
    func rejectionKeepsSeverity() async throws {
        let plain = try await audit(try fixture("security.sql-injection"))
        let rejected = try await audit(marked(try fixture("security.sql-injection"),
                                              with: "// SECURITY: parameterised upstream"))
        let before = try #require(plain.diagnostics.first { $0.ruleId == "security.sql-injection" })
        let after = try #require(rejected.diagnostics.first { $0.ruleId == "security.sql-injection" })
        #expect(before.severity == after.severity)
    }

    // MARK: - Scope

    /// `// SAFETY:` excuses a force unwrap. It used to excuse a hard-coded secret on the same
    /// line too, because the safety markers were passed to the security visitor.
    @Test("A safety marker does not reach security rules", arguments: ruleIds)
    func safetyMarkerDoesNotSilenceSecurity(rule: String) async throws {
        let marker = "// SAFETY: fixture input is a compile-time constant and never reaches a user"
        let result = try await audit(marked(try fixture(rule), with: marker))
        #expect(result.diagnostics.contains { $0.ruleId == rule }, "\(rule) was silenced by // SAFETY:")
    }

    @Test("A safety marker still excuses a safety finding")
    func safetyMarkerStillWorksForSafety() async throws {
        let result = try await audit("""
            // SAFETY: the dictionary literal above always contains this key
            let value = table["k"]!
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "force-unwrap" })
    }
}
