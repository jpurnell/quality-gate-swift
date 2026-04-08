import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: variable shadowing")
struct ShadowingTests {
    @Test("Does not flag inner shadowing var with the same name as the bound pointer")
    func ignoresShadowedName() async throws {
        let code = """
        func use(_ x: Int) {
            withUnsafePointer(to: x) { ptr in
                let ptr = 5
                print(ptr)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.isEmpty)
    }
}
