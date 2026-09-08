import Foundation
import Testing
@testable import RecursionAuditor
@testable import QualityGateCore

/// Pass 1 resolves names lexically; it does not match them.
///
/// Every "does not flag" fixture here is reduced from a real site in the 22-package
/// survey corpus, and every one of them compiles and terminates — which is the
/// independent evidence that today's finding is false. See
/// `quality-gate-swift-project/plans/proposals/RecursionNeedsScopeTracking.md`.
@Suite("Pass 1 lexical resolution")
struct LexicalResolutionTests {

    // MARK: - Key paths reference another type's member (35 corpus sites)

    @Test("A key path naming the property is not a self-reference")
    func keyPathIsNotSelfReference() async throws {
        // Alamofire — Source/Core/Request.swift:255. `\.retryCount` is a key path
        // into `MutableState`, not a reference to this property.
        let code = """
        struct MutableState { var retryCount: Int = 0 }
        struct Request {
            let mutableState = Protected(MutableState())
            public var retryCount: Int { mutableState.read(\\.retryCount) }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("A key path inside a nested closure is not a self-reference")
    func keyPathInClosureIsNotSelfReference() async throws {
        // GRDB — GRDB/QueryInterface/SQL/SQLRelation.swift:701.
        let code = """
        struct Element {
            var terms: [[Element]] = []
            var reversed: Element { Element(terms: terms.map { $0.map(\\.reversed) }) }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    // MARK: - Local declarations shadow the property (30 corpus sites)

    @Test("A plain local var of the same name shadows the property")
    func plainLocalVarShadows() async throws {
        // swift-nio — Tests/NIOFSTests/FileInfoTests.swift:46.
        let code = """
        struct Stat { var mode: Int = 0 }
        struct Info {
            private var status: Stat {
                var status = Stat()
                status.mode = 1
                return status
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("A local declared in an if-let body shadows the property")
    func localInIfLetBodyShadows() async throws {
        // GRDB — GRDB/Core/Database.swift:2260. The binding is a VariableDecl in the
        // body, and the body is a sibling of the condition, not a child of it.
        let code = """
        struct Statement {
            var unexpandedSQL: String?
            public var sql: String {
                if let unexpandedSQL {
                    let sql = String(unexpandedSQL.reversed())
                    return sql.hasPrefix("--") ? sql : sql
                }
                return ""
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("A guard-case-let binding shadows the property for the rest of the scope")
    func guardCaseLetShadows() async throws {
        // Alamofire — Source/Core/DataStreamRequest.swift:508.
        let code = """
        enum Event { case complete(Int) }
        struct Stream {
            let event = Event.complete(1)
            var completion: Int? {
                guard case let .complete(completion) = event else { return nil }
                return completion
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    // MARK: - A method of the same name is a different declaration (12 corpus sites)

    @Test("A property calling a same-named method is not self-recursive")
    func propertyCallingSameNamedMethodIsNotRecursive() async throws {
        // Ignite — Sources/Ignite/Extensions/Date-ISO8601.swift:12.
        let code = """
        extension Date {
            // Swift permits this pair because the method's full name is
            // `asISO8601(timeZone:)`; a no-argument `asISO8601()` would be a
            // redeclaration and would not compile.
            public func asISO8601(timeZone: TimeZone? = nil) -> String { "" }
            public var asISO8601: String { asISO8601() }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    // MARK: - Regression guards: genuine self-recursion must still gate

    @Test("A bare self-reference in the getter still errors")
    func genuineSelfReferenceStillErrors() async throws {
        let code = """
        struct Foo {
            var name: String { name }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("An explicit self.name reference in the getter still errors")
    func genuineExplicitSelfReferenceStillErrors() async throws {
        let code = """
        struct Foo {
            var name: String { self.name }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("A binding in a sibling closure scope does not mask a real self-reference")
    func siblingScopeBindingDoesNotMaskRecursion() async throws {
        // The closure declares `value`, but the trailing `return value` is outside it
        // and genuinely re-enters the getter. Popping the closure's scope is what
        // keeps this an error.
        let code = """
        struct Foo {
            var value: Int {
                let f = { () -> Int in
                    let value = 1
                    return value
                }
                _ = f()
                return value
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("A self-reference used as the base of a member access still errors")
    func selfReferenceAsMemberBaseStillErrors() async throws {
        // Previously missed: the old walker skipped every child of a member access
        // to avoid matching the member name, and skipped the base along with it.
        let code = """
        struct Foo {
            var name: String { name.uppercased() }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("A same-named member on another value is not a self-reference")
    func memberOnOtherValueIsNotSelfReference() async throws {
        let code = """
        struct Other { var name: String = "" }
        struct Foo {
            let other = Other()
            var name: String { other.name }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("A local of the same name does not shadow an explicit self reference")
    func localDoesNotShadowExplicitSelf() async throws {
        // `self.name` names the property whatever locals exist, so this is genuine
        // infinite recursion and must still gate.
        let code = """
        struct Foo {
            var name: String {
                let name = "x"
                _ = name
                return self.name
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("An explicit self call to a same-named method is not self-recursive")
    func explicitSelfCallToSameNamedMethod() async throws {
        let code = """
        struct Foo {
            func render(style: Int = 0) -> String { "" }
            var render: String { self.render() }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    private func audit(_ code: String) async throws -> CheckResult {
        let auditor = RecursionAuditor()
        let config = Configuration(recursion: RecursionAuditorConfig(useIndexStore: false))
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
