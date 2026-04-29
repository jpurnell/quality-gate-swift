import Foundation
import Testing
@testable import RecursionAuditor
@testable import QualityGateCore

/// Tests for RecursionAuditor.
///
/// Each test pairs a "red" fixture (must flag) with a "green" fixture (must NOT flag)
/// to keep the auditor's precision honest.
@Suite("RecursionAuditor Tests")
struct RecursionAuditorTests {

    // MARK: - Identity

    @Test("RecursionAuditor has correct id and name")
    func checkerIdentity() {
        let auditor = RecursionAuditor()
        #expect(auditor.id == "recursion")
        #expect(auditor.name == "Recursion Auditor")
    }

    // MARK: - Convenience init self-recursion

    @Test("Flags convenience init forwarding to itself with identical args")
    func flagsConvenienceInitSelfForward() async throws {
        let code = """
        class Foo {
            init(name: String, age: Int) {
                self.name = name
                self.age = age
            }
            convenience init(name: String) {
                self.init(name: name)
            }
            let name: String
            let age: Int
        }
        """
        let result = try await audit(code)
        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.convenience-init-self" })
    }

    @Test("Does not flag convenience init forwarding to a different init")
    func ignoresConvenienceInitForwardingToDifferentInit() async throws {
        let code = """
        class Foo {
            init(name: String, age: Int) {
                self.name = name
                self.age = age
            }
            convenience init(name: String) {
                self.init(name: name, age: 0)
            }
            let name: String
            let age: Int
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.convenience-init-self" })
    }

    // MARK: - Computed property self-reference

    @Test("Flags computed property whose getter returns itself")
    func flagsComputedPropertySelfReference() async throws {
        let code = """
        struct Foo {
            var value: Int { value }
        }
        """
        let result = try await audit(code)
        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("Does not flag computed property delegating to backing storage")
    func ignoresComputedPropertyBackingStorage() async throws {
        let code = """
        struct Foo {
            private let _value: Int = 0
            var value: Int { _value }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    // MARK: - Subscript self-reference

    @Test("Flags subscript whose getter calls itself with the same key")
    func flagsSubscriptSelfReference() async throws {
        let code = """
        struct Foo {
            subscript(i: Int) -> Int { self[i] }
        }
        """
        let result = try await audit(code)
        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.subscript-self" })
    }

    @Test("Does not flag subscript that delegates to a different key")
    func ignoresSubscriptDelegatingToDifferentKey() async throws {
        let code = """
        struct Foo {
            let storage: [Int]
            subscript(i: Int) -> Int { storage[i] }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.subscript-self" })
    }

    // MARK: - Function unconditional self-call (warning tier)

    @Test("Flags function with no base case calling itself unconditionally")
    func flagsUnconditionalSelfCall() async throws {
        let code = """
        func loop(_ n: Int) -> Int {
            return loop(n)
        }
        """
        let result = try await audit(code)
        let warnings = result.diagnostics.filter { $0.ruleId == "recursion.unconditional-self-call" }
        #expect(!warnings.isEmpty)
        #expect(warnings.allSatisfy { $0.severity == .warning })
    }

    @Test("Does not flag function with guard-driven base case")
    func ignoresFunctionWithBaseCase() async throws {
        let code = """
        func countdown(_ n: Int) -> Int {
            guard n > 0 else { return 0 }
            return countdown(n - 1)
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    // MARK: - Mutual recursion (intra-file, warning tier)

    @Test("Flags intra-file mutual recursion with no base case")
    func flagsMutualRecursionWithoutBaseCase() async throws {
        let code = """
        func a() { b() }
        func b() { a() }
        """
        let result = try await audit(code)
        let cycles = result.diagnostics.filter { $0.ruleId == "recursion.mutual-cycle" }
        #expect(cycles.count >= 2, "Expected both participants of the cycle to be flagged")
        #expect(cycles.allSatisfy { $0.severity == .warning })
    }

    @Test("Does not flag intra-file mutual recursion that has a base case")
    func ignoresMutualRecursionWithBaseCase() async throws {
        let code = """
        func a(_ n: Int) {
            guard n > 0 else { return }
            b(n - 1)
        }
        func b(_ n: Int) {
            a(n - 1)
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.mutual-cycle" })
    }

    // MARK: - Diagnostic quality

    @Test("Reports accurate line numbers")
    func reportsLineNumbers() async throws {
        let code = """
        struct Foo {
            var value: Int { value }
        }
        """
        let result = try await audit(code)
        let diag = result.diagnostics.first { $0.ruleId == "recursion.computed-property-self" }
        #expect(diag?.lineNumber == 2)
    }

    // MARK: - Computed property robustness

    @Test("Flags computed property using explicit self and return")
    func flagsComputedPropertyExplicitSelfReturn() async throws {
        let code = """
        struct Foo {
            var value: Int {
                return self.value
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("Flags computed property where one branch self-references")
    func flagsComputedPropertyBranchSelfReference() async throws {
        let code = """
        struct Foo {
            var flag: Bool { false }
            var value: Int {
                if flag {
                    return value
                }
                return 0
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    // MARK: - Setter recursion

    @Test("Flags property setter that writes to itself")
    func flagsSetterSelfReference() async throws {
        let code = """
        struct Foo {
            private var _value: Int = 0
            var value: Int {
                get { _value }
                set { value = newValue }
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.setter-self" })
    }

    @Test("Does not flag property setter that writes to backing storage")
    func ignoresSetterWritingBackingStorage() async throws {
        let code = """
        struct Foo {
            private var _value: Int = 0
            var value: Int {
                get { _value }
                set { _value = newValue }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.setter-self" })
    }

    // MARK: - Subscript setter recursion

    @Test("Flags subscript setter writing to itself with same key")
    func flagsSubscriptSetterSelfReference() async throws {
        let code = """
        struct Foo {
            var storage: [Int] = []
            subscript(i: Int) -> Int {
                get { storage[i] }
                set { self[i] = newValue }
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.subscript-setter-self" })
    }

    @Test("Does not flag subscript setter writing to backing storage")
    func ignoresSubscriptSetterWritingBackingStorage() async throws {
        let code = """
        struct Foo {
            var storage: [Int] = []
            subscript(i: Int) -> Int {
                get { storage[i] }
                set { storage[i] = newValue }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.subscript-setter-self" })
    }

    // MARK: - Instance & static method recursion

    @Test("Flags instance method that calls itself unconditionally")
    func flagsInstanceMethodSelfCall() async throws {
        let code = """
        struct Foo {
            func loop() { loop() }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("Flags static method that calls itself unconditionally")
    func flagsStaticMethodSelfCall() async throws {
        let code = """
        struct Foo {
            static func loop() { loop() }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("Flags mutual recursion between two instance methods of the same type")
    func flagsIntraTypeMutualRecursion() async throws {
        let code = """
        class Foo {
            func a() { b() }
            func b() { a() }
        }
        """
        let result = try await audit(code)
        let cycles = result.diagnostics.filter { $0.ruleId == "recursion.mutual-cycle" }
        #expect(cycles.count >= 2)
    }

    // MARK: - Protocol extension defaults

    @Test("Flags protocol extension default that calls itself")
    func flagsProtocolExtensionDefaultSelfCall() async throws {
        let code = """
        protocol P {
            func f()
        }
        extension P {
            func f() { f() }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.protocol-extension-default-self" })
    }

    @Test("Does not flag protocol extension default that delegates to a different requirement")
    func ignoresProtocolExtensionDelegatingToOtherRequirement() async throws {
        let code = """
        protocol P {
            func core()
        }
        extension P {
            func f() { core() }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.protocol-extension-default-self" })
    }

    // MARK: - Cross-type mutual recursion

    @Test("Flags cross-type mutual recursion within a single file")
    func flagsCrossTypeMutualRecursion() async throws {
        let code = """
        struct A {
            func f() { B().g() }
        }
        struct B {
            func g() { A().f() }
        }
        """
        let result = try await audit(code)
        let cycles = result.diagnostics.filter { $0.ruleId == "recursion.mutual-cycle" }
        #expect(cycles.count >= 2)
    }

    // MARK: - 3-node mutual cycle

    @Test("Flags 3-node mutual cycle a -> b -> c -> a")
    func flagsThreeNodeCycle() async throws {
        let code = """
        func a() { b() }
        func b() { c() }
        func c() { a() }
        """
        let result = try await audit(code)
        let cycles = result.diagnostics.filter { $0.ruleId == "recursion.mutual-cycle" }
        #expect(cycles.count >= 3, "All three participants should be flagged")
    }

    // MARK: - Nested functions

    @Test("Flags nested function that calls itself")
    func flagsNestedFunctionSelfCall() async throws {
        let code = """
        func outer() {
            func inner() {
                inner()
            }
            inner()
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    // MARK: - Generic / async / throwing recursion

    @Test("Flags generic function recursion")
    func flagsGenericFunctionRecursion() async throws {
        let code = """
        func f<T>(_ x: T) -> T {
            return f(x)
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("Flags async function recursion")
    func flagsAsyncFunctionRecursion() async throws {
        let code = """
        func f() async {
            await f()
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("Flags throwing function recursion")
    func flagsThrowingFunctionRecursion() async throws {
        let code = """
        func f() throws {
            try f()
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    // MARK: - Overload resolution

    @Test("Does not flag call to a different overload as self-recursion")
    func ignoresCallToDifferentOverload() async throws {
        let code = """
        func f(_ x: Int) { f(x: x) }
        func f(x: Int) { }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    // MARK: - Indirect enums (legitimate recursive types)

    @Test("Does not flag indirect enum recursive case")
    func ignoresIndirectEnum() async throws {
        let code = """
        indirect enum List {
            case node(Int, List)
            case end
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - Multi-file (auditProject)

    @Test("Flags cross-file mutual recursion via auditProject")
    func flagsCrossFileMutualRecursion() async throws {
        let sources: [(fileName: String, source: String)] = [
            ("A.swift", "func a() { b() }"),
            ("B.swift", "func b() { a() }")
        ]
        let result = try await RecursionAuditor().auditProject(sources: sources, configuration: Configuration())
        let cycles = result.diagnostics.filter { $0.ruleId == "recursion.mutual-cycle" }
        #expect(cycles.count >= 2)
    }

    @Test("Does not flag cross-file mutual recursion that has a base case")
    func ignoresCrossFileMutualRecursionWithBaseCase() async throws {
        let sources: [(fileName: String, source: String)] = [
            ("A.swift", """
            func a(_ n: Int) {
                guard n > 0 else { return }
                b(n - 1)
            }
            """),
            ("B.swift", """
            func b(_ n: Int) {
                a(n - 1)
            }
            """)
        ]
        let result = try await RecursionAuditor().auditProject(sources: sources, configuration: Configuration())
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.mutual-cycle" })
    }

    // MARK: - Diagnostic message quality

    @Test("Diagnostic message names the offending symbol")
    func diagnosticMessageNamesSymbol() async throws {
        let code = """
        struct Foo {
            var value: Int { value }
        }
        """
        let result = try await audit(code)
        let diag = result.diagnostics.first { $0.ruleId == "recursion.computed-property-self" }
        #expect(diag?.message.contains("value") == true)
    }

    @Test("Diagnostic includes a column number")
    func diagnosticHasColumn() async throws {
        let code = """
        struct Foo {
            var value: Int { value }
        }
        """
        let result = try await audit(code)
        let diag = result.diagnostics.first { $0.ruleId == "recursion.computed-property-self" }
        #expect(diag?.columnNumber != nil)
    }

    // MARK: - Helper

    private func audit(_ code: String) async throws -> CheckResult {
        let auditor = RecursionAuditor()
        let config = Configuration()
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
