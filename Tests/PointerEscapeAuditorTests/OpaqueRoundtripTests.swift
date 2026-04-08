import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: opaque pointer round-trip")
struct OpaqueRoundtripTests {
    private let ruleId = "pointer-escape.opaque-roundtrip"

    @Test("Flags OpaquePointer round-trip outside the with-block")
    func flagsRoundtripOutside() async throws {
        let code = """
        func leak(_ x: Int) -> UnsafePointer<Int> {
            let opaque = withUnsafePointer(to: x) { OpaquePointer($0) }
            return UnsafePointer<Int>(opaque)
        }
        """
        let result = try await TestHelpers.audit(code)
        let hits = result.diagnostics.filter { $0.ruleId == ruleId }
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.severity == .warning })
    }

    @Test("Does not flag round-trip kept inside the with-block")
    func ignoresRoundtripInside() async throws {
        let code = """
        func use(_ x: Int) -> Int {
            withUnsafePointer(to: x) { ptr in
                let opaque = OpaquePointer(ptr)
                let typed = UnsafePointer<Int>(opaque)
                return typed.pointee
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
