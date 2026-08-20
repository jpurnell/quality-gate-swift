import Foundation
import Testing
@testable import RecursionAuditor
@testable import QualityGateCore

/// `self[…]` is not automatically a recursive subscript call.
///
/// A type may declare several subscripts, and `self[key: k]` inside `subscript(sub:)`
/// selects a different one. SwiftyJSON declares five and every one of its findings
/// crossed between them. Argument labels settle most of it; where two subscripts share
/// labels and differ only by parameter type, syntax cannot decide and the site is
/// recorded as `recursion.self-reference-unresolved`.
@Suite("Subscript resolution")
struct SubscriptResolutionTests {

    @Test("A self-subscript with different labels is a different subscript")
    func differentLabelsAreADifferentSubscript() async throws {
        // SwiftyJSON — SwiftyJSON.swift:412. `subscript(sub:)` delegates to
        // `subscript(index:)` and `subscript(key:)`.
        let code = """
        struct JSON {
            fileprivate subscript(index index: Int) -> JSON { JSON() }
            fileprivate subscript(key key: String) -> JSON { JSON() }
            fileprivate subscript(sub sub: Int) -> JSON {
                get { self[index: sub] }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.subscript-self" })
    }

    @Test("A self-subscript matching an overloaded signature is unresolved")
    func overloadedSubscriptIsUnresolved() async throws {
        // SwiftyJSON — SwiftyJSON.swift:477. The variadic subscript forwards to the
        // array subscript; both are unlabelled, so only the parameter type separates
        // them.
        let code = """
        struct JSON {
            subscript(path: [Int]) -> JSON { JSON() }
            subscript(path: Int...) -> JSON {
                get { self[path] }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.subscript-self" })
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.self-reference-unresolved" })
    }

    @Test("A lone subscript calling itself still errors")
    func loneSubscriptSelfCallStillErrors() async throws {
        let code = """
        struct Box {
            subscript(index: Int) -> Int {
                get { self[index] }
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.subscript-self" })
    }

    @Test("A setter assigning to a different subscript is not recursive")
    func setterToDifferentSubscriptIsNotRecursive() async throws {
        let code = """
        struct JSON {
            subscript(index index: Int) -> Int {
                get { 0 }
                set {}
            }
            subscript(sub sub: Int) -> Int {
                get { 0 }
                set { self[index: sub] = newValue }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.subscript-setter-self" })
    }

    @Test("A setter assigning to itself still errors")
    func setterSelfAssignmentStillErrors() async throws {
        let code = """
        struct Box {
            subscript(index: Int) -> Int {
                get { 0 }
                set { self[index] = newValue }
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.subscript-setter-self" })
    }

    @Test("A subscript with different arity is a different subscript")
    func differentArityIsADifferentSubscript() async throws {
        let code = """
        struct Grid {
            subscript(row: Int, column: Int) -> Int { 0 }
            subscript(index: Int) -> Int {
                get { self[index, 0] }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.subscript-self" })
    }

    @Test("An extension of a nested type shares the nested type's context")
    func extensionOfNestedTypeSharesContext() async throws {
        // GRDB — Row.swift:2460. `struct ScopesView` nested in `Row` has context
        // "Row.ScopesView"; `extension Row.ScopesView` produced only "ScopesView",
        // so the two subscripts never met in the census.
        let code = """
        struct Row {
            struct ScopesView {
                subscript(_ name: String) -> Int { self[0] }
            }
        }
        extension Row.ScopesView {
            subscript(_ position: Int) -> Int { 0 }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.subscript-self" })
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.self-reference-unresolved" })
    }

    private func audit(_ code: String) async throws -> CheckResult {
        let auditor = RecursionAuditor()
        let config = Configuration(recursion: RecursionAuditorConfig(useIndexStore: false))
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
