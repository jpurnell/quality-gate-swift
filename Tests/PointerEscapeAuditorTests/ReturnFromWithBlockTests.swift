import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: return from with-block")
struct ReturnFromWithBlockTests {
    private let ruleId = "pointer-escape.return-from-with-block"

    @Test("PointerEscapeAuditor identity")
    func identity() {
        let auditor = PointerEscapeAuditor()
        #expect(auditor.id == "pointer-escape")
        #expect(auditor.name == "Pointer Escape Auditor")
    }

    // MARK: - Direct return

    @Test("Flags implicit-return single-expression closure returning $0")
    func flagsImplicitReturn() async throws {
        let code = """
        func leak(_ x: Int) -> UnsafePointer<Int> {
            withUnsafePointer(to: x) { $0 }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags explicit return $0")
    func flagsExplicitReturn() async throws {
        let code = """
        func leak(_ x: Int) -> UnsafePointer<Int> {
            withUnsafePointer(to: x) { return $0 }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags named parameter return")
    func flagsNamedParamReturn() async throws {
        let code = """
        func leak(_ x: Int) -> UnsafePointer<Int> {
            withUnsafePointer(to: x) { ptr in
                return ptr
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags return of .baseAddress from buffer pointer")
    func flagsReturnBaseAddress() async throws {
        let code = """
        func leak(_ a: [Int]) -> UnsafePointer<Int>? {
            a.withUnsafeBufferPointer { $0.baseAddress }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags return of pointer arithmetic result")
    func flagsReturnPointerArithmetic() async throws {
        let code = """
        func leak(_ x: Int) -> UnsafePointer<Int> {
            withUnsafePointer(to: x) { $0 + 1 }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags return of advanced(by:)")
    func flagsReturnAdvancedBy() async throws {
        let code = """
        func leak(_ x: Int) -> UnsafePointer<Int> {
            withUnsafePointer(to: x) { $0.advanced(by: 1) }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags alias-then-return")
    func flagsAliasThenReturn() async throws {
        let code = """
        func leak(_ x: Int) -> UnsafePointer<Int> {
            withUnsafePointer(to: x) { ptr in
                let alias = ptr
                return alias
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Wrapped return

    @Test("Flags pointer wrapped in struct initializer")
    func flagsStructWrappedReturn() async throws {
        let code = """
        struct Holder {
            let ptr: UnsafePointer<Int>
        }
        func leak(_ x: Int) -> Holder {
            withUnsafePointer(to: x) { ptr in
                return Holder(ptr: ptr)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags pointer wrapped in tuple")
    func flagsTupleWrappedReturn() async throws {
        let code = """
        func leak(_ x: Int) -> (UnsafePointer<Int>, Int) {
            withUnsafePointer(to: x) { ptr in
                return (ptr, 0)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags pointer wrapped in array literal")
    func flagsArrayLiteralReturn() async throws {
        let code = """
        func leak(_ x: Int) -> [UnsafePointer<Int>] {
            withUnsafePointer(to: x) { ptr in
                return [ptr]
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags pointer boxed in Any")
    func flagsAnyBoxedReturn() async throws {
        let code = """
        func leak(_ x: Int) -> Any {
            withUnsafePointer(to: x) { ptr in
                let boxed: Any = ptr
                return boxed
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags ternary branch returning pointer")
    func flagsTernaryReturn() async throws {
        let code = """
        func leak(_ x: Int, _ flag: Bool, _ other: UnsafePointer<Int>) -> UnsafePointer<Int> {
            withUnsafePointer(to: x) { ptr in
                return flag ? ptr : other
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags non-tail return inside if branch")
    func flagsNonTailBranchReturn() async throws {
        let code = """
        func leak(_ x: Int, _ flag: Bool) -> UnsafePointer<Int>? {
            withUnsafePointer(to: x) { ptr in
                if flag {
                    return ptr
                }
                return nil
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must NOT flag

    @Test("Does not flag returning .pointee value")
    func ignoresReturnPointee() async throws {
        let code = """
        func use(_ x: Int) -> Int {
            withUnsafePointer(to: x) { $0.pointee }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag buffer reduction")
    func ignoresBufferReduction() async throws {
        let code = """
        func sum(_ a: [Int]) -> Int {
            a.withUnsafeBufferPointer { $0.reduce(0, +) }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag closure with discarded $0")
    func ignoresUnusedParam() async throws {
        let code = """
        func noop(_ x: Int) {
            withUnsafePointer(to: x) { _ in
                print("ignored")
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
