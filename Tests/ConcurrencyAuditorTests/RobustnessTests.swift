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
        _ = try await TestHelpers.audit(code)
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
        _ = try await TestHelpers.audit(code)
    }

    @Test("Does not crash on syntactically malformed input")
    func malformedSourceDoesNotCrash() async throws {
        let code = """
        actor A {
            func f(
        """
        _ = try await TestHelpers.audit(code)
    }

    @Test("Does not crash on macro-expanded code")
    func macroDoesNotCrash() async throws {
        let code = """
        @Observable
        final class Foo {
            var x = 0
        }
        """
        _ = try await TestHelpers.audit(code)
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
        _ = try await TestHelpers.audit(code)
    }
}
