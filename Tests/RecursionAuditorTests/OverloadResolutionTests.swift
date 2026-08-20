import Foundation
import Testing
@testable import RecursionAuditor
@testable import QualityGateCore

/// Argument labels are part of a function's identity, but they are not all of it.
///
/// Two declarations sharing a base name *and* labels differ only in parameter types,
/// which a syntactic pass cannot resolve: GRDB's `encode(_ value: Int16)` calling
/// `encode(value.databaseValue)` targets a sibling overload, not itself, and fourteen
/// such `encode(_:)` overloads sit in one file. Where syntax cannot decide, the pass
/// says so rather than guessing — `recursion.self-reference-unresolved` at `.note`,
/// which is measurable and does not gate. The index pass has the compiler's answer.
@Suite("Overload resolution")
struct OverloadResolutionTests {

    @Test("A call matching an overloaded signature is reported as unresolved, not recursion")
    func overloadedSignatureIsUnresolved() async throws {
        // GRDB — DatabaseValueConvertible+Encodable.swift:23.
        let code = """
        struct Value { var databaseValue: DatabaseValue { DatabaseValue() } }
        struct DatabaseValue {}
        struct Encoder {
            mutating func encode(_ value: Int16) throws { try encode(value.databaseValue) }
            mutating func encode(_ value: DatabaseValue) throws {}
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.self-reference-unresolved" })
    }

    @Test("The unresolved note does not gate")
    func unresolvedNoteIsNotAnError() async throws {
        let code = """
        struct Encoder {
            mutating func encode(_ value: Int16) throws { try encode(value.description) }
            mutating func encode(_ value: String) throws {}
        }
        """
        let result = try await audit(code)
        let note = result.diagnostics.first { $0.ruleId == "recursion.self-reference-unresolved" }
        #expect(note?.severity == .note)
    }

    @Test("An unambiguous signature still reports genuine self-recursion")
    func unambiguousSignatureStillWarns() async throws {
        // Only one `descend(_:)` exists, so a call matching its labels is this function.
        let code = """
        struct Loop {
            func descend(_ n: Int) -> Int { descend(n - 1) }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.self-reference-unresolved" })
    }

    @Test("Overloads differing in labels are already distinguished and stay unambiguous")
    func differingLabelsRemainUnambiguous() async throws {
        let code = """
        struct Loop {
            func step(_ n: Int) -> Int { step(n - 1) }
            func step(count n: Int) -> Int { 0 }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.self-reference-unresolved" })
    }

    @Test("An overloaded protocol extension default is unresolved rather than an error")
    func overloadedProtocolDefaultIsUnresolved() async throws {
        let code = """
        protocol Renderer {
            func render(_ value: Int) -> String
            func render(_ value: String) -> String
        }
        extension Renderer {
            func render(_ value: Int) -> String { render(String(value)) }
            func render(_ value: String) -> String { value }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.protocol-extension-default-self" })
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.self-reference-unresolved" })
    }

    @Test("A protocol requirement and its default implementation are not an overload pair")
    func requirementPlusDefaultIsNotAnOverload() async throws {
        // They share a signature but are one function. Counting the pair as two would
        // silence the rule that exists to catch exactly this shape.
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
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.self-reference-unresolved" })
    }

    @Test("An overload declared in another file is still an overload")
    func overloadAcrossFilesIsAmbiguous() async throws {
        // swift-collections — `_ptr(at: Bucket)` calling `_ptr(at: Int)`. A Swift type
        // spans files, so a per-file census cannot see the sibling.
        let a = ("A.swift", """
        struct Bucket { var offset: Int = 0 }
        struct Table {
            func ptr(at bucket: Bucket) -> Int { ptr(at: bucket.offset) }
        }
        """)
        let b = ("B.swift", """
        extension Table {
            func ptr(at offset: Int) -> Int { offset }
        }
        """)
        let auditor = RecursionAuditor()
        let config = Configuration(recursion: RecursionAuditorConfig(useIndexStore: false))
        let result = try await auditor.auditProject(sources: [a, b], configuration: config)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.self-reference-unresolved" })
    }

    private func audit(_ code: String) async throws -> CheckResult {
        let auditor = RecursionAuditor()
        let config = Configuration(recursion: RecursionAuditorConfig(useIndexStore: false))
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
