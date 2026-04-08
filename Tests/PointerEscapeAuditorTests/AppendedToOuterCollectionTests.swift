import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: appended to outer collection")
struct AppendedToOuterCollectionTests {
    private let ruleId = "pointer-escape.appended-to-outer-collection"

    @Test("Flags append of pointer to outer array")
    func flagsAppendToArray() async throws {
        let code = """
        func leak(_ x: Int) {
            var storage: [UnsafePointer<Int>] = []
            withUnsafePointer(to: x) { ptr in
                storage.append(ptr)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags insert of pointer to outer array")
    func flagsInsertIntoArray() async throws {
        let code = """
        func leak(_ x: Int) {
            var storage: [UnsafePointer<Int>] = []
            withUnsafePointer(to: x) { ptr in
                storage.insert(ptr, at: 0)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag append of pointee value")
    func ignoresAppendValue() async throws {
        let code = """
        func use(_ x: Int) {
            var storage: [Int] = []
            withUnsafePointer(to: x) { ptr in
                storage.append(ptr.pointee)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
