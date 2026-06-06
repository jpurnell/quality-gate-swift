import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

/// Edge-case robustness tests. The auditor must not crash on any of these
/// inputs. Whether or not it produces diagnostics is secondary — what matters
/// is that it returns a result rather than throwing or trapping.
@Suite("ConcurrencyAuditor: edge-case robustness")
struct RobustnessTests {

    @Test("Does not crash on generic class with Sendable constraint")
    func genericConstraintDoesNotCrash() async throws {
        let code = """
        final class Foo<T>: Sendable where T: Sendable {
            let value: T
            init(_ v: T) { self.value = v }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.checkerId == "concurrency")
        #expect(result.diagnostics.isEmpty)
        #expect(result.status == .passed)
    }

    @Test("Does not crash on conditional compilation branches")
    func conditionalCompilationDoesNotCrash() async throws {
        let code = """
        #if DEBUG
        final class Foo: @unchecked Sendable {}
        #else
        final class Foo: Sendable {
            let x = 0
        }
        #endif
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.checkerId == "concurrency")
        // Both branches are parsed; the DEBUG branch contains @unchecked Sendable
        // without justification, so the auditor should produce at least one diagnostic.
        #expect(!result.diagnostics.isEmpty)
    }

    @Test("Does not crash on syntactically malformed input")
    func malformedSourceDoesNotCrash() async throws {
        let code = """
        actor A {
            func f(
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.checkerId == "concurrency")
    }

    @Test("Does not crash on macro-expanded code")
    func macroDoesNotCrash() async throws {
        let code = """
        @Observable
        final class Foo {
            var x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.checkerId == "concurrency")
        // @Observable class without Sendable conformance: no concurrency diagnostics expected.
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Does not crash on multiline declaration spanning many lines")
    func multilineDeclarationDoesNotCrash() async throws {
        let code = """
        final
        class
        Foo
        :
        Sendable
        {
            var x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.checkerId == "concurrency")
        // Sendable class with mutable var → should flag mutable state.
        #expect(result.diagnostics.contains { $0.ruleId == "concurrency.sendable-class-mutable-state" })
    }
}
