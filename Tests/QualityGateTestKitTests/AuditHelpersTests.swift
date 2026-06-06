import Foundation
import Testing
@testable import QualityGateTestKit
@testable import QualityGateCore
@testable import SafetyAuditor

// SafetyAuditor already has auditSource(_:fileName:configuration:), so conformance is trivial.
extension SafetyAuditor: SourceAuditable {}

/// Integration tests for ``auditSource(_:fileName:with:configuration:)``.
///
/// Uses ``SafetyAuditor`` as a real auditor to verify the helper
/// correctly delegates and returns results.
@Suite("AuditHelpers Integration Tests")
struct AuditHelpersTests {

    @Test("auditSource with force unwrap code returns diagnostics")
    func auditSourceWithViolation() async throws {
        let code = """
        func risky() {
            let x: Int? = nil
            let y = x!
        }
        """

        let result = try await auditSource(code, with: SafetyAuditor())

        expectStatus(result, .failed)
        expectDiagnostic(in: result, ruleId: "force-unwrap")
        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "force-unwrap" })
    }

    @Test("auditSource with clean code returns empty diagnostics")
    func auditSourceClean() async throws {
        let code = """
        func safe() {
            let x: Int? = nil
            if let y = x {
                _ = y
            }
        }
        """

        let result = try await auditSource(code, with: SafetyAuditor())

        expectClean(result)
        expectStatus(result, .passed)
        #expect(result.diagnostics.isEmpty)
        #expect(result.status == .passed)
    }

    @Test("auditSource with custom fileName works")
    func auditSourceCustomFileName() async throws {
        let code = """
        func risky() {
            let y = optional!
        }
        """

        let result = try await auditSource(
            code,
            fileName: "CustomFile.swift",
            with: SafetyAuditor()
        )

        // The audit should still detect the violation regardless of file name.
        expectStatus(result, .failed)
        expectDiagnostic(in: result, ruleId: "force-unwrap")
        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "force-unwrap" })
    }
}
