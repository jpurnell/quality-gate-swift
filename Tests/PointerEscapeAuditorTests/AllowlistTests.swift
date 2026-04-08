import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: allowlist")
struct AllowlistTests {
    @Test("Does not flag escape into allowlisted function")
    func ignoresAllowlistedFunction() async throws {
        let code = """
        func vDSP_fft_zip(_ p: UnsafePointer<Int>) {}
        func use(_ x: Int) {
            withUnsafePointer(to: x) { ptr in
                vDSP_fft_zip(ptr)
            }
        }
        """
        let result = try await TestHelpers.audit(code, allowedEscapeFunctions: ["vDSP_fft_zip"])
        // Even if the visitor would otherwise treat passing into an unknown function
        // conservatively, the allowlist must suppress any pointer-escape diagnostics
        // tied to this call.
        #expect(result.diagnostics.allSatisfy { $0.ruleId?.hasPrefix("pointer-escape.") != true })
    }

    @Test("Still flags escape into a non-allowlisted function")
    func flagsNonAllowlistedFunction() async throws {
        let code = """
        var leaked: UnsafePointer<Int>?
        func store(_ p: UnsafePointer<Int>) { leaked = p }
        func leak(_ x: Int) {
            withUnsafePointer(to: x) { ptr in
                store(ptr)
            }
        }
        """
        let result = try await TestHelpers.audit(code, allowedEscapeFunctions: ["vDSP_fft_zip"])
        // The auditor should still produce some pointer-escape diagnostic for the
        // non-allowlisted store call (precise rule may be assigned-to-outer-capture
        // via the call site, depending on GREEN implementation).
        #expect(result.diagnostics.contains { $0.ruleId?.hasPrefix("pointer-escape.") == true })
    }
}
