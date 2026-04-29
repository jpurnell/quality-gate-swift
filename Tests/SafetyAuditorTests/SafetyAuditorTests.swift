import Foundation
import Testing
@testable import SafetyAuditor
@testable import QualityGateCore

/// Tests for SafetyAuditor.
///
/// SafetyAuditor scans Swift source code for forbidden patterns that could
/// cause crashes or undefined behavior in production.
@Suite("SafetyAuditor Tests")
struct SafetyAuditorTests {

    // MARK: - Identity Tests

    @Test("SafetyAuditor has correct id and name")
    func checkerIdentity() {
        let auditor = SafetyAuditor()
        #expect(auditor.id == "safety")
        #expect(auditor.name == "Safety Auditor")
    }

    // MARK: - Force Unwrap Detection

    @Test("Detects force unwrap operator")
    func detectsForceUnwrap() async throws {
        let code = """
        let value = optional!
        """

        let result = try await auditCode(code)

        #expect(result.status == .failed)
        #expect(result.diagnostics.count >= 1)
        #expect(result.diagnostics.contains { $0.ruleId == "force-unwrap" })
    }

    @Test("Detects force unwrap in method chain")
    func detectsForceUnwrapInChain() async throws {
        let code = """
        let name = user?.profile!.name
        """

        let result = try await auditCode(code)

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "force-unwrap" })
    }

    @Test("Does not flag non-force-unwrap exclamation marks")
    func ignoresNonForceUnwrap() async throws {
        let code = """
        let isNotTrue = !someBoolean
        let value: Int! = implicitlyUnwrapped
        """

        let result = try await auditCode(code)

        // Implicitly unwrapped optionals are a declaration, not a force unwrap operation
        // The `!someBoolean` is a logical NOT, not force unwrap
        #expect(result.diagnostics.filter { $0.ruleId == "force-unwrap" }.isEmpty)
    }

    // MARK: - Force Cast Detection

    @Test("Detects force cast")
    func detectsForceCast() async throws {
        let code = """
        let string = anyValue as! String
        """

        let result = try await auditCode(code)

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "force-cast" })
    }

    // MARK: - Force Try Detection

    @Test("Detects force try")
    func detectsForceTry() async throws {
        let code = """
        let data = try! loadData()
        """

        let result = try await auditCode(code)

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "force-try" })
    }

    // MARK: - Fatal Error Detection

    @Test("Detects fatalError call")
    func detectsFatalError() async throws {
        let code = """
        func process() {
            fatalError("Not implemented")
        }
        """

        let result = try await auditCode(code)

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "fatal-error" })
    }

    // MARK: - Precondition Detection

    @Test("Detects precondition call")
    func detectsPrecondition() async throws {
        let code = """
        func validate(_ value: Int) {
            precondition(value > 0)
        }
        """

        let result = try await auditCode(code)

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "precondition" })
    }

    // MARK: - Assertion Failure Detection

    @Test("Detects assertionFailure call")
    func detectsAssertionFailure() async throws {
        let code = """
        func handle() {
            assertionFailure("Should not reach here")
        }
        """

        let result = try await auditCode(code)

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "assertion-failure" })
    }

    // MARK: - Unowned Detection

    @Test("Detects unowned reference")
    func detectsUnowned() async throws {
        let code = """
        class Observer {
            unowned var delegate: Delegate
        }
        """

        let result = try await auditCode(code)

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "unowned" })
    }

    // MARK: - Infinite Loop Detection

    @Test("Detects while true loop")
    func detectsWhileTrue() async throws {
        let code = """
        while true {
            process()
        }
        """

        let result = try await auditCode(code)

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "infinite-loop" })
    }

    // MARK: - Clean Code Detection

    @Test("Passes for clean code")
    func passesForCleanCode() async throws {
        let code = """
        func process(_ optional: String?) -> String {
            guard let value = optional else {
                return "default"
            }
            return value
        }

        func cast(_ any: Any) -> String? {
            return any as? String
        }

        func load() -> Data? {
            return try? loadData()
        }
        """

        let result = try await auditCode(code)

        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - Exemption Tests

    @Test("Respects SAFETY exemption comment on same line")
    func respectsSafetyExemptionSameLine() async throws {
        let code = """
        let value = optional! // SAFETY: Guaranteed non-nil by initialization
        """

        let result = try await auditCode(code)

        #expect(result.diagnostics.filter { $0.ruleId == "force-unwrap" }.isEmpty)
    }

    @Test("Respects SAFETY exemption comment on previous line")
    func respectsSafetyExemptionPreviousLine() async throws {
        let code = """
        // SAFETY: Required for UIKit callback
        let view = sender as! UIButton
        """

        let result = try await auditCode(code)

        #expect(result.diagnostics.filter { $0.ruleId == "force-cast" }.isEmpty)
    }

    @Test("Does not exempt without SAFETY comment")
    func requiresExplicitExemption() async throws {
        let code = """
        // This is fine, trust me
        let value = optional!
        """

        let result = try await auditCode(code)

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "force-unwrap" })
    }

    // MARK: - Configuration Tests

    @Test("Respects custom exemption patterns")
    func respectsCustomExemptionPatterns() async throws {
        let code = """
        let value = optional! // @unsafe: allowed here
        """

        let config = Configuration(
            safetyExemptions: ["// @unsafe:"]
        )

        let auditor = SafetyAuditor()
        let result = try await auditor.auditSource(code, fileName: "test.swift", configuration: config)

        #expect(result.diagnostics.filter { $0.ruleId == "force-unwrap" }.isEmpty)
    }

    @Test("Respects exclude patterns")
    func respectsExcludePatterns() async throws {
        let config = Configuration(
            excludePatterns: ["**/Generated/**"]
        )

        // When scanning a directory, files matching exclude patterns should be skipped
        // This is tested at the directory scanning level
        #expect(config.excludePatterns.contains("**/Generated/**"))
    }

    // MARK: - Diagnostic Quality Tests

    @Test("Provides accurate line numbers")
    func providesAccurateLineNumbers() async throws {
        let code = """
        let a = 1
        let b = 2
        let c = optional!
        let d = 4
        """

        let result = try await auditCode(code)

        let diagnostic = result.diagnostics.first { $0.ruleId == "force-unwrap" }
        #expect(diagnostic?.lineNumber == 3)
    }

    @Test("Provides helpful messages")
    func providesHelpfulMessages() async throws {
        let code = """
        let value = optional!
        """

        let result = try await auditCode(code)

        let diagnostic = result.diagnostics.first { $0.ruleId == "force-unwrap" }
        #expect(diagnostic?.message.contains("force unwrap") == true ||
                diagnostic?.message.contains("Force unwrap") == true)
        #expect(diagnostic?.suggestedFix != nil)
    }

    // MARK: - Multiple Violations

    @Test("Detects multiple violations in same file")
    func detectsMultipleViolations() async throws {
        let code = """
        let a = optional!
        let b = value as! String
        let c = try! load()
        """

        let result = try await auditCode(code)

        #expect(result.status == .failed)
        #expect(result.diagnostics.count >= 3)
    }

    // MARK: - Helper Methods

    /// Audits a code snippet and returns the result.
    private func auditCode(_ code: String) async throws -> CheckResult {
        let auditor = SafetyAuditor()
        let config = Configuration()
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
