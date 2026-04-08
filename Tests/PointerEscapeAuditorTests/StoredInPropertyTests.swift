import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: stored in property")
struct StoredInPropertyTests {
    private let ruleId = "pointer-escape.stored-in-property"

    @Test("Flags assignment to self.cachedPtr from baseAddress")
    func flagsSelfPropertyAssignment() async throws {
        let code = """
        final class Cache {
            var cachedPtr: UnsafePointer<Int>?
            func capture(_ a: [Int]) {
                a.withUnsafeBufferPointer { buf in
                    self.cachedPtr = buf.baseAddress
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags assignment via computed property setter")
    func flagsComputedPropertySetter() async throws {
        let code = """
        final class Cache {
            private var _ptr: UnsafePointer<Int>?
            var ptr: UnsafePointer<Int>? {
                get { _ptr }
                set { _ptr = newValue }
            }
            func capture(_ x: Int) {
                withUnsafePointer(to: x) { p in
                    self.ptr = p
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag storing pointee value")
    func ignoresStoringValue() async throws {
        let code = """
        final class Cache {
            var first: Int = 0
            func capture(_ a: [Int]) {
                a.withUnsafeBufferPointer { buf in
                    self.first = buf.first ?? 0
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
