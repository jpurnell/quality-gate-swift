import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: nested with-block scopes")
struct NestedScopeTests {
    private let returnRule = "pointer-escape.return-from-with-block"

    @Test("Flags inner closure returning the outer with-block pointer")
    func flagsInnerReturnsOuter() async throws {
        let code = """
        func leak(_ x: Int, _ y: Int) -> UnsafePointer<Int> {
            withUnsafePointer(to: x) { outer in
                withUnsafePointer(to: y) { inner in
                    return outer
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == returnRule })
    }

    @Test("Flags inner closure assigning outer pointer to outer-outer var")
    func flagsInnerAssignsOuter() async throws {
        let code = """
        func leak(_ x: Int, _ y: Int) {
            var leaked: UnsafePointer<Int>?
            withUnsafePointer(to: x) { outer in
                withUnsafePointer(to: y) { inner in
                    leaked = outer
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "pointer-escape.assigned-to-outer-capture" })
    }

    @Test("Does not flag nested closures using only their own pointer")
    func ignoresLocalNestedUse() async throws {
        let code = """
        func use(_ x: Int, _ y: Int) -> Int {
            withUnsafePointer(to: x) { outer in
                withUnsafePointer(to: y) { inner in
                    return outer.pointee + inner.pointee
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.isEmpty)
    }
}
