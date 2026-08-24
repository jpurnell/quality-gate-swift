import Foundation
import Testing
@testable import RecursionAuditor
@testable import QualityGateCore

/// Argument labels do not identify a Swift function.
///
/// The overload census counted declarations per `Signature` — type context, base name,
/// argument labels — which is a strict prefix of Swift's identity. Where a package uses
/// the remainder to disambiguate, two functions collided and a call to the sibling read
/// as a call to self. Eleven of the twenty-one findings left in the 22-package survey
/// were this, across GRDB, SQLite.swift, TCA, and swift-nio.
@Suite("A name is not an identity")
struct TypeDiscriminatorTests {

    // MARK: - The rule must still fire

    @Test("A requirement and its default are one function, and still error")
    func canonicalInfiniteRecursionStillErrors() async throws {
        // The regression guard for everything below: the census must not become so
        // permissive that the shape the rule exists for stops being reported.
        let code = """
        protocol Q { func g() }
        extension Q { func g() { g() } }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.protocol-extension-default-self" })
    }

    // MARK: - Separated by parameter type

    @Test("Overloads differing by parameter type are unresolved, not recursion")
    func differingParameterTypesDemote() async throws {
        // GRDB's `forKey(_:)`: `some CodingKey` delegating to `String`.
        let code = """
        protocol Keyed { func forKey(_ key: String) -> Self }
        extension Keyed {
            func forKey(_ key: some CustomStringConvertible) -> Self {
                forKey(key.description)
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.protocol-extension-default-self" })
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.self-reference-unresolved" })
    }

    // MARK: - Separated by effects and return type only

    @Test("Overloads differing only in async and return type are unresolved")
    func differingEffectsDemote() async throws {
        // swift-nio's `setOption`. The two declarations have *identical* parameter types;
        // only `async` and the return type separate them. A discriminator built from
        // parameter types alone would miss this, which is why it carries effects too.
        let code = """
        protocol Channel {
            func getOption(_ option: Int) -> Box
        }
        extension Channel {
            func getOption(_ option: Int) async throws -> Int {
                try await getOption(option).get()
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.protocol-extension-default-self" })
    }

    // MARK: - `throws` is deliberately not a discriminant

    @Test("A non-throwing default still matches its throwing requirement")
    func throwsIsNotADiscriminant() async throws {
        // swift-nio's `scheduleCallback(at:handler:)`. A non-throwing default legally
        // satisfies a throwing requirement, so comparing `throws` would separate a
        // requirement from its own default and silence a real finding.
        let code = """
        protocol Sched { func fire(_ x: Int) throws }
        extension Sched { func fire(_ x: Int) { try? fire(x) } }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.protocol-extension-default-self" })
    }

    // MARK: - Initializers

    @Test("Convenience inits overloading on parameter type are unresolved")
    func convenienceInitOverloadsDemote() async throws {
        // SQLite.swift's `Connection`: the String overload delegates to the Location one.
        // This rule reported its finding directly and never consulted the census at all,
        // so no amount of fixing the census would have reached it.
        let code = """
        class Connection {
            init(_ location: Int, readonly: Bool) { }
            convenience init(_ filename: String, readonly: Bool) {
                self.init(filename.count, readonly: readonly)
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.convenience-init-self" })
    }

    @Test("A convenience init that truly forwards to itself still errors")
    func genuineSelfForwardingInitStillErrors() async throws {
        let code = """
        class Loop {
            convenience init(_ x: Int) {
                self.init(x)
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.convenience-init-self" })
    }

    // MARK: - Normalization

    @Test("Sugar spellings normalize to one discriminator")
    func sugarNormalizes() {
        #expect(normalizeTypeSpelling("Array<Int>") == normalizeTypeSpelling("[Int]"))
        #expect(normalizeTypeSpelling("Optional<String>") == normalizeTypeSpelling("String?"))
        #expect(normalizeTypeSpelling("Dictionary<String, Int>") == normalizeTypeSpelling("[String: Int]"))
        #expect(normalizeTypeSpelling("Self.SerializedObject") == normalizeTypeSpelling("SerializedObject"))
        #expect(normalizeTypeSpelling("[ Int ]") == normalizeTypeSpelling("[Int]"))
        #expect(normalizeTypeSpelling("[Int]") != normalizeTypeSpelling("[String]"))
    }

    private func audit(_ code: String) async throws -> CheckResult {
        let auditor = RecursionAuditor()
        let config = Configuration(recursion: RecursionAuditorConfig(useIndexStore: false))
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
