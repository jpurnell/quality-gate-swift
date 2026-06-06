import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

/// Edge-case robustness — auditor must not crash on any of these inputs.
@Suite("PointerEscapeAuditor: edge-case robustness")
struct RobustnessTests {

    @Test("Does not crash on conditional compilation")
    func conditionalCompilationDoesNotCrash() async throws {
        let code = """
        #if DEBUG
        func leak(_ x: Int) -> UnsafePointer<Int> {
            withUnsafePointer(to: x) { $0 }
        }
        #else
        func use(_ x: Int) -> Int {
            withUnsafePointer(to: x) { $0.pointee }
        }
        #endif
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.checkerId == "pointer-escape")
        // The DEBUG branch leaks a pointer via implicit return — should flag.
        #expect(!result.diagnostics.isEmpty)
    }

    @Test("Does not crash on macro-expanded code")
    func macroDoesNotCrash() async throws {
        let code = """
        @Observable
        final class Foo {
            var x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.checkerId == "pointer-escape")
        // No pointer operations → no diagnostics expected.
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Does not crash on malformed input")
    func malformedDoesNotCrash() async throws {
        let code = """
        func leak(_ x: Int) {
            withUnsafePointer(to: x) {
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.checkerId == "pointer-escape")
    }

    @Test("Does not crash on switch return inside with-block")
    func switchReturnDoesNotCrash() async throws {
        let code = """
        func leak(_ x: Int, _ flag: Int) -> UnsafePointer<Int>? {
            withUnsafePointer(to: x) { ptr in
                switch flag {
                case 0: return ptr
                default: return nil
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.checkerId == "pointer-escape")
        // Returning ptr from switch inside withUnsafePointer is a pointer escape.
        #expect(result.diagnostics.contains { $0.ruleId == "pointer-escape.return-from-with-block" })
    }

    @Test("Does not crash on guard-let return")
    func guardReturnDoesNotCrash() async throws {
        let code = """
        func use(_ x: Int, _ opt: Int?) -> Int {
            withUnsafePointer(to: x) { ptr in
                guard let value = opt else { return 0 }
                return ptr.pointee + value
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.checkerId == "pointer-escape")
        // ptr.pointee is a safe dereference (Int), not a pointer escape.
        #expect(result.diagnostics.isEmpty)
    }
}
