import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: stored closure captures pointer")
struct StoredClosureCapturesPointerTests {
    private let ruleId = "pointer-escape.stored-closure-captures-pointer"

    @Test("Flags closure literal stored to outer var capturing pointer")
    func flagsClosureToOuterVar() async throws {
        let code = """
        func leak(_ x: Int) {
            var closure: (() -> Void)?
            withUnsafePointer(to: x) { ptr in
                closure = { print(ptr.pointee) }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags closure literal stored to self.handler")
    func flagsClosureToSelfProperty() async throws {
        let code = """
        final class Holder {
            var handler: (() -> Void)?
            func capture(_ x: Int) {
                withUnsafePointer(to: x) { ptr in
                    self.handler = { _ = ptr.pointee }
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags returning closure that captures pointer")
    func flagsReturnedClosure() async throws {
        let code = """
        func leak(_ x: Int) -> () -> Void {
            withUnsafePointer(to: x) { ptr in
                return { _ = ptr.pointee }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag closure used locally inside the with-block")
    func ignoresLocallyInvokedClosure() async throws {
        let code = """
        func use(_ x: Int) {
            withUnsafePointer(to: x) { ptr in
                let local = { _ = ptr.pointee }
                local()
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
