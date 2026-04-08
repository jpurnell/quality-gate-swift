import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: assigned to outer capture")
struct AssignedToOuterCaptureTests {
    private let ruleId = "pointer-escape.assigned-to-outer-capture"

    // MARK: - Must flag

    @Test("Flags assignment to outer local var")
    func flagsLocalOuterVar() async throws {
        let code = """
        func leak(_ x: Int) {
            var leaked: UnsafePointer<Int>?
            withUnsafePointer(to: x) { ptr in
                leaked = ptr
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags assignment to global var")
    func flagsGlobalVar() async throws {
        let code = """
        var globalPtr: UnsafePointer<Int>?
        func leak(_ x: Int) {
            withUnsafePointer(to: x) { ptr in
                globalPtr = ptr
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags assignment to static property")
    func flagsStaticProperty() async throws {
        let code = """
        enum Cache {
            static var lastPtr: UnsafePointer<Int>?
        }
        func leak(_ x: Int) {
            withUnsafePointer(to: x) { ptr in
                Cache.lastPtr = ptr
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags assignment inside defer block")
    func flagsAssignmentInDefer() async throws {
        let code = """
        func leak(_ x: Int) {
            var leaked: UnsafePointer<Int>?
            withUnsafePointer(to: x) { ptr in
                defer {
                    leaked = ptr
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must NOT flag

    @Test("Does not flag assignment of pointee value")
    func ignoresPointeeAssignment() async throws {
        let code = """
        func use(_ x: Int) {
            var leaked: Int = 0
            withUnsafePointer(to: x) { ptr in
                leaked = ptr.pointee
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag local-only alias")
    func ignoresLocalAlias() async throws {
        let code = """
        func use(_ x: Int) {
            withUnsafePointer(to: x) { ptr in
                let alias = ptr
                print(alias.pointee)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
