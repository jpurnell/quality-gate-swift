import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: captured by escaping closure (warning)")
struct EscapingClosureWarningTests {
    private let ruleId = "pointer-escape.captured-by-escaping-closure"

    @Test("Flags pointer captured by DispatchQueue.async closure")
    func flagsDispatchQueueAsync() async throws {
        let code = """
        func leak(_ x: Int) {
            withUnsafePointer(to: x) { ptr in
                DispatchQueue.global().async {
                    _ = ptr.pointee
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        let hits = result.diagnostics.filter { $0.ruleId == ruleId }
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.severity == .warning })
    }

    @Test("Flags pointer captured by Task closure")
    func flagsTaskClosure() async throws {
        let code = """
        func leak(_ x: Int) {
            withUnsafePointer(to: x) { ptr in
                Task {
                    _ = ptr.pointee
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag synchronous DispatchQueue.sync closure")
    func ignoresSyncDispatch() async throws {
        let code = """
        func use(_ x: Int) {
            withUnsafePointer(to: x) { ptr in
                DispatchQueue.global().sync {
                    _ = ptr.pointee
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag forEach (non-escaping) usage")
    func ignoresForEach() async throws {
        let code = """
        func use(_ x: Int, _ items: [Int]) {
            withUnsafePointer(to: x) { ptr in
                items.forEach { _ in
                    _ = ptr.pointee
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
