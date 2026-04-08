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
        _ = try await TestHelpers.audit(code)
    }

    @Test("Does not crash on macro-expanded code")
    func macroDoesNotCrash() async throws {
        let code = """
        @Observable
        final class Foo {
            var x = 0
        }
        """
        _ = try await TestHelpers.audit(code)
    }

    @Test("Does not crash on malformed input")
    func malformedDoesNotCrash() async throws {
        let code = """
        func leak(_ x: Int) {
            withUnsafePointer(to: x) {
        """
        _ = try await TestHelpers.audit(code)
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
        _ = try await TestHelpers.audit(code)
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
        _ = try await TestHelpers.audit(code)
    }
}
