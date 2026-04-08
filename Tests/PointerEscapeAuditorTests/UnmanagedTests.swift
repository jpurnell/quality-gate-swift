import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

@Suite("PointerEscapeAuditor: Unmanaged retain leak")
struct UnmanagedTests {
    private let ruleId = "pointer-escape.unmanaged-retain-leak"

    @Test("Flags passRetained stored without matching release")
    func flagsRetainWithoutRelease() async throws {
        let code = """
        final class Holder {
            var handle: UnsafeMutableRawPointer?
            func capture(_ obj: AnyObject) {
                self.handle = Unmanaged.passRetained(obj).toOpaque()
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        let hits = result.diagnostics.filter { $0.ruleId == ruleId }
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.severity == .warning })
    }

    @Test("Does not flag passRetained with deinit release")
    func ignoresBalancedRetainRelease() async throws {
        let code = """
        final class Holder {
            var handle: UnsafeMutableRawPointer?
            func capture(_ obj: AnyObject) {
                self.handle = Unmanaged.passRetained(obj).toOpaque()
            }
            deinit {
                if let handle {
                    Unmanaged<AnyObject>.fromOpaque(handle).release()
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag passUnretained")
    func ignoresPassUnretained() async throws {
        let code = """
        final class Holder {
            var handle: UnsafeMutableRawPointer?
            func capture(_ obj: AnyObject) {
                self.handle = Unmanaged.passUnretained(obj).toOpaque()
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
