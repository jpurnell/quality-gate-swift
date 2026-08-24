import Foundation
import Testing
@testable import RecursionAuditor
@testable import QualityGateCore

/// A trailing closure is an argument.
///
/// `callArgumentLabels` read only the parenthesized list, so `f(x) { }` measured as one
/// argument rather than two — and a call to a *different, longer* overload matched the
/// enclosing declaration instead. Three findings in the 22-package survey were this:
/// swift-nio's `shutdownGracefully()` calling `shutdownGracefully(_:)`, and TCA's
/// `ifLet(_:action:)` / `forEach(_:action:)` calling their `destination:` overloads —
/// each documented in its own doc comment as "a special overload of" the thing it calls.
@Suite("Trailing closures count toward call arity")
struct TrailingClosureArityTests {

    @Test("A trailing-closure call to a longer overload is not a self-call")
    func trailingClosureCallToLongerOverloadIsNotSelfCall() async throws {
        // swift-nio's shape: the no-argument overload delegates to the one-argument one.
        let code = """
        protocol Group {
            func shutdownGracefully(_ callback: @escaping (Error?) -> Void)
        }
        extension Group {
            public func shutdownGracefully() async throws {
                self.shutdownGracefully { _ in }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains {
            $0.ruleId == "recursion.protocol-extension-default-self"
                || $0.ruleId == "recursion.unconditional-self-call"
        })
    }

    @Test("A trailing-closure call that does match arity is still a self-call")
    func trailingClosureSelfCallStillCaught() async throws {
        // The guard must not mute genuine recursion: arity matches and the parameter is
        // unlabelled, so `run { }` can only be `run(_:)`.
        let code = """
        protocol Runner {
            func run(_ body: () -> Void)
        }
        extension Runner {
            func run(_ body: () -> Void) {
                run { }
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.protocol-extension-default-self" })
    }

    @Test("Multiple trailing closures each count")
    func multipleTrailingClosuresCount() async throws {
        let code = """
        protocol Loader {
            func load(_ url: String, onSuccess: () -> Void, onFailure: () -> Void)
        }
        extension Loader {
            func load(_ url: String) {
                load(url) { } onFailure: { }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.protocol-extension-default-self" })
    }

    @Test("A trailing closure filling a labelled parameter is not asserted")
    func labelledTrailingPositionIsNotAsserted() async throws {
        // GRDB's `filter(country:)` calls `filter { $0.country == country }` — the
        // closure-taking `filter(_:)`, a different function. Arity matches (1 == 1), so
        // arity alone accepted it. The declaration labels that position `country:`, which
        // is the signal that the call is at best ambiguous. Five findings appeared in the
        // GRDB corpus run from getting this wrong before it was measured.
        let code = """
        protocol Filtered {
            func filter(_ predicate: (Int) -> Bool) -> Self
        }
        extension Filtered {
            func filter(country: String) -> Self {
                filter { $0 == country.count }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.protocol-extension-default-self" })
    }

    @Test("A convenience init delegating via a trailing closure is not self-forwarding")
    func convenienceInitTrailingClosure() async throws {
        let code = """
        class Store {
            init(_ name: String, build: () -> Int) { }
            convenience init(_ name: String) {
                self.init(name) { 0 }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.convenience-init-self" })
    }

    @Test("A trailing closure cannot fill a non-function parameter")
    func trailingClosureNeedsFunctionTypedParameter() async throws {
        // GRDB's `DatabaseCancellable.init(_ base: some DatabaseCancellable)` writes
        // `self.init { base.cancel() }`, which reaches `init(cancel:)`. Label and arity
        // both admit the enclosing init; the parameter type is what rules it out — a
        // closure literal cannot be a `some DatabaseCancellable`.
        let code = """
        class Cancellable {
            init(cancel: @escaping () -> Void) { }
            convenience init(_ base: Cancellable) {
                self.init { base.stop() }
            }
            func stop() { }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.convenience-init-self" })
    }

    private func audit(_ code: String) async throws -> CheckResult {
        let auditor = RecursionAuditor()
        let config = Configuration(recursion: RecursionAuditorConfig(useIndexStore: false))
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
