import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: passed as inout")
struct PassedAsInoutTests {
    private let ruleId = "pointer-escape.passed-as-inout"

    @Test("Flags passing tracked pointer alongside inout outer var")
    func flagsInoutAssignmentVehicle() async throws {
        let code = """
        func assign(_ p: inout UnsafePointer<Int>?, _ src: UnsafePointer<Int>) {
            p = src
        }
        func leak(_ x: Int) {
            var leaked: UnsafePointer<Int>?
            withUnsafePointer(to: x) { ptr in
                assign(&leaked, ptr)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag inout call that doesn't include the tracked pointer")
    func ignoresInoutCallWithoutPointer() async throws {
        let code = """
        func bump(_ p: inout Int) { p += 1 }
        func use(_ x: Int) {
            var counter = 0
            withUnsafePointer(to: x) { _ in
                bump(&counter)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
