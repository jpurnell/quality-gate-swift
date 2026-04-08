import Foundation
import Testing
@testable import UnreachableCodeAuditor
@testable import QualityGateCore

/// Tests for UnreachableCodeAuditor.
///
/// Detects syntactically unreachable code: statements after terminators,
/// branches of constant conditions, and unused private symbols.
@Suite("UnreachableCodeAuditor Tests")
struct UnreachableCodeAuditorTests {

    // MARK: - Identity

    @Test("UnreachableCodeAuditor has correct id and name")
    func checkerIdentity() {
        let auditor = UnreachableCodeAuditor()
        #expect(auditor.id == "unreachable")
        #expect(auditor.name == "Unreachable Code Auditor")
    }

    // MARK: - Post-terminator

    @Test("Detects code after return")
    func detectsCodeAfterReturn() async throws {
        let code = """
        func f() -> Int {
            return 1
            let x = 2
            return x
        }
        """
        let result = try await audit(code)
        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "unreachable.after_terminator" })
    }

    @Test("Detects code after throw")
    func detectsCodeAfterThrow() async throws {
        let code = """
        enum E: Error { case bad }
        func f() throws {
            throw E.bad
            print("dead")
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "unreachable.after_terminator" })
    }

    @Test("Detects code after fatalError")
    func detectsCodeAfterFatalError() async throws {
        let code = """
        func f() -> Int {
            fatalError("nope")
            return 0
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "unreachable.after_terminator" })
    }

    @Test("Detects code after break in loop")
    func detectsCodeAfterBreak() async throws {
        let code = """
        func f() {
            for _ in 0..<3 {
                break
                print("dead")
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "unreachable.after_terminator" })
    }

    @Test("Does not flag normal control flow")
    func cleanCodePasses() async throws {
        let code = """
        func f(_ x: Int) -> Int {
            if x > 0 { return x }
            return -x
        }
        """
        let result = try await audit(code)
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - Constant condition

    @Test("Detects if false dead branch")
    func detectsIfFalse() async throws {
        let code = """
        func f() {
            if false {
                print("dead")
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "unreachable.dead_branch" })
    }

    @Test("Detects if true else dead branch")
    func detectsIfTrueElse() async throws {
        let code = """
        func f() {
            if true {
                print("live")
            } else {
                print("dead")
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "unreachable.dead_branch" })
    }

    // MARK: - Unused private

    @Test("Detects unused private function")
    func detectsUnusedPrivateFunc() async throws {
        let code = """
        struct S {
            private func unused() {}
            func used() {}
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "unreachable.unused_private" })
    }

    @Test("Does not flag used private function")
    func usedPrivateFuncPasses() async throws {
        let code = """
        struct S {
            private func helper() -> Int { 1 }
            func use() -> Int { helper() }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "unreachable.unused_private" })
    }

    @Test("Detects unused fileprivate function")
    func detectsUnusedFileprivate() async throws {
        let code = """
        fileprivate func zombie() {}
        func main() {}
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "unreachable.unused_private" })
    }

    // MARK: - Helpers

    private func audit(_ source: String) async throws -> CheckResult {
        let auditor = UnreachableCodeAuditor()
        return try await auditor.auditSource(source, fileName: "Test.swift", configuration: Configuration())
    }
}
