import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

/// An extension has the isolation of the type it extends, when the run can read that
/// type's declaration.
@Suite("ConcurrencyAuditor: extension isolation")
struct ExtensionIsolationTests {
    private let taskRule = "concurrency.task-captures-self-no-isolation"
    private let dispatchRule = "concurrency.dispatch-queue-in-actor"

    private func count(_ rule: String, in code: String) async throws -> Int {
        try await TestHelpers.audit(code).diagnostics.filter { $0.ruleId == rule }.count
    }

    private func count(_ rule: String, inFiles files: [String: String]) -> Int {
        TestHelpers.audit(files: files).diagnostics.filter { $0.ruleId == rule }.count
    }

    private let mainActorClass = """
    @MainActor
    class A { var x = 0 }

    """

    // MARK: - Must flag

    @Test("Task in a same-file extension of a @MainActor class")
    func flagsTaskInSameFileExtensionOfMainActorClass() async throws {
        let code = mainActorClass + "extension A { func f() { Task { self.x = 1 } } }"
        #expect(try await count(taskRule, in: code) == 1)
    }

    @Test("Implicit self in a same-file extension")
    func flagsImplicitSelfInSameFileExtension() async throws {
        let code = mainActorClass + "extension A { func f() { Task { x = 1 } } }"
        #expect(try await count(taskRule, in: code) == 1)
    }

    @Test("DispatchQueue in a same-file extension of a @MainActor class")
    func flagsDispatchQueueInSameFileExtensionOfMainActorClass() async throws {
        let code = mainActorClass + "extension A { func f() { DispatchQueue.main.async {} } }"
        #expect(try await count(dispatchRule, in: code) == 1)
    }

    @Test("Task in an extension of an actor")
    func flagsTaskInExtensionOfActor() async throws {
        let code = """
        actor Act { var x = 0 }
        extension Act { func f() { Task { self.x = 1 } } }
        """
        #expect(try await count(taskRule, in: code) == 1)
    }

    @Test("DispatchQueue in an extension of an actor")
    func flagsDispatchQueueInExtensionOfActor() async throws {
        let code = """
        actor Act { var x = 0 }
        extension Act { func f() { DispatchQueue.global().async {} } }
        """
        #expect(try await count(dispatchRule, in: code) == 1)
    }

    @Test("Implicit self in an annotated extension")
    func flagsImplicitSelfInAnnotatedExtension() async throws {
        let code = mainActorClass + "@MainActor extension A { func f() { Task { x = 1 } } }"
        #expect(try await count(taskRule, in: code) == 1)
    }

    @Test("A conformance extension is isolated like any other")
    func flagsInConformanceExtension() async throws {
        let code = mainActorClass + """
        protocol P { func req() }
        extension A: P { func req() { DispatchQueue.main.async {} } }
        """
        #expect(try await count(dispatchRule, in: code) == 1)
    }

    @Test("A static member in an extension of a @MainActor type is isolated")
    func flagsStaticMemberOfMainActorTypeExtension() async throws {
        let code = mainActorClass + "extension A { static func s() { DispatchQueue.main.async {} } }"
        #expect(try await count(dispatchRule, in: code) == 1)
    }

    @Test("An extension with a benign attribute still inherits")
    func flagsInAvailabilityAttributedExtension() async throws {
        let code = mainActorClass + "@available(macOS 15, *) extension A { func f() { DispatchQueue.main.async {} } }"
        #expect(try await count(dispatchRule, in: code) == 1)
    }

    @Test("An extension in another file of the same module")
    func flagsInOtherFileExtension() {
        let files = [
            "Sources/M/A.swift": mainActorClass,
            "Sources/M/A+More.swift": """
            extension A {
                func f() {
                    Task { x = 1 }
                    DispatchQueue.main.async {}
                }
            }
            """,
        ]
        #expect(count(taskRule, inFiles: files) == 1)
        #expect(count(dispatchRule, inFiles: files) == 1)
    }

    @Test("An extension in another module that imports the type's module")
    func flagsInOtherModuleExtensionWhenImported() {
        let files = [
            "Sources/Core/A.swift": mainActorClass,
            "Sources/App/A+App.swift": """
            import Core
            extension A { func f() { DispatchQueue.main.async {} } }
            extension Core.A { func g() { DispatchQueue.main.async {} } }
            """,
        ]
        #expect(count(dispatchRule, inFiles: files) == 2)
    }

    @Test("An extension of a nested type")
    func flagsExtensionOfNestedType() async throws {
        let code = """
        struct Outer {
            @MainActor
            class Inner { var x = 0 }
        }
        extension Outer.Inner { func f() { Task { x = 1 } } }
        """
        #expect(try await count(taskRule, in: code) == 1)
    }

    @Test("An extension of a generic type, with arguments or a where clause")
    func flagsExtensionOfGenericType() async throws {
        let code = """
        @MainActor
        final class Box<T> { var value: T?; var x = 0 }
        extension Box<Int> { func f() { DispatchQueue.main.async {} } }
        extension Box where T: Sendable { func g() { DispatchQueue.main.async {} } }
        """
        #expect(try await count(dispatchRule, in: code) == 2)
    }

    @Test("A @MainActor Task in a nonisolated member of an extension of a @MainActor type")
    func flagsMainActorHopInNonisolatedExtensionMember() async throws {
        let code = mainActorClass + """
        extension A {
            nonisolated func cb() {
                Task { @MainActor in self.x = 1 }
            }
        }
        """
        #expect(try await count(taskRule, in: code) == 1)
    }

    // MARK: - Must not flag

    @Test("An extension of a type the run cannot read is left as it was")
    func ignoresExtensionOfUnknownType() async throws {
        let code = """
        extension NSViewController {
            func f() {
                Task { self.title = "x" }
                DispatchQueue.main.async {}
            }
        }
        """
        #expect(try await count(taskRule, in: code) == 0)
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    @Test("A module the file does not import is not consulted")
    func ignoresExtensionWhenModuleIsNotImported() {
        let files = [
            "Sources/Core/A.swift": mainActorClass,
            "Sources/App/A+App.swift": "extension A { func f() { DispatchQueue.main.async {} } }",
        ]
        #expect(count(dispatchRule, inFiles: files) == 0)
    }

    @Test("A name whose declarations disagree on isolation is unknown")
    func ignoresExtensionWhenNameIsAmbiguous() {
        let files = [
            "Sources/M/One.swift": "@MainActor final class Model { var x = 0 }",
            "Sources/M/Nested/Two.swift": "enum Namespace {}\nstruct Model { var y = 0 }",
            "Sources/M/Model+More.swift": "extension Model { func f() { DispatchQueue.main.async {} } }",
        ]
        #expect(count(dispatchRule, inFiles: files) == 0)
    }

    @Test("A type nested in an isolated extension does not inherit")
    func ignoresNestedTypeDeclaredInIsolatedExtension() async throws {
        let code = mainActorClass + """
        extension A {
            struct S {
                func f() { DispatchQueue.main.async {} }
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    @Test("An extension carrying another global actor is not treated as the type's")
    func ignoresExtensionWithOtherGlobalActor() async throws {
        let code = mainActorClass + "@DatabaseActor extension A { func f() { DispatchQueue.main.async {} } }"
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    @Test("An extension of a plain type stays unisolated, across files too")
    func ignoresExtensionOfPlainType() {
        let files = [
            "Sources/M/Plain.swift": "struct Plain { var x = 0 }",
            "Sources/M/Plain+More.swift": "extension Plain { func f() { Task { x }; DispatchQueue.main.async {} } }",
        ]
        #expect(count(dispatchRule, inFiles: files) == 0)
        #expect(count(taskRule, inFiles: files) == 0)
    }
}

// MARK: - The table

@Suite("ConcurrencyAuditor: isolation table")
struct IsolationTableTests {
    private func table(_ files: [String: String]) -> IsolationTable {
        ConcurrencyAuditor.isolationTable(forSources: files)
    }

    @Test("Nested declarations are recorded under qualified names")
    func qualifiedNames() {
        let table = table(["Sources/M/A.swift": """
        struct Outer {
            @MainActor final class Inner { var x = 0 }
        }
        extension Outer {
            actor Worker { var jobs = 0 }
        }
        """])
        #expect(table.resolve(typeName: "Outer.Inner", fromFile: "Sources/M/A.swift")?.isolation == .mainActor)
        #expect(table.resolve(typeName: "Outer.Worker", fromFile: "Sources/M/A.swift")?.isolation == .actor(name: "Worker"))
        #expect(table.resolve(typeName: "Outer", fromFile: "Sources/M/A.swift")?.isolation == IsolationContext.none)
        #expect(table.resolve(typeName: "Inner", fromFile: "Sources/M/A.swift") == nil)
    }

    @Test(
        "A file's module bucket follows the SwiftPM layout",
        arguments: [
            ("Sources/T/File.swift", "T"),
            ("Sources/T/Sub/File.swift", "T"),
            ("Tests/TTests/File.swift", "TTests"),
            ("Plugins/Tool/plugin.swift", "Tool"),
            ("Sources/main.swift", "Sources"),
            ("App/Views/File.swift", "App"),
            ("File.swift", ""),
        ]
    )
    func bucketAssignment(path: String, bucket: String) {
        #expect(IsolationTable.moduleBucket(ofFile: path, root: "") == bucket)
    }

    @Test("A root prefix is removed before the bucket is read")
    func bucketIgnoresRootPrefix() {
        let bucket = IsolationTable.moduleBucket(
            ofFile: "/Users/dev/Sources/project/Sources/T/File.swift",
            root: "/Users/dev/Sources/project/")
        #expect(bucket == "T")
    }

    @Test("resolve refuses on disagreement, a non-imported bucket, and an unknown name")
    func resolveRefuses() {
        let table = table([
            "Sources/Core/A.swift": "@MainActor final class A { var x = 0 }",
            "Sources/Core/Model.swift": "@MainActor final class Model {}",
            "Sources/Core/Model2.swift": "enum Scope { }\nstruct Model {}",
            "Sources/App/Uses.swift": "import Core",
            "Sources/Other/NoImport.swift": "import Foundation",
        ])
        #expect(table.resolve(typeName: "Model", fromFile: "Sources/Core/A.swift") == nil)
        #expect(table.resolve(typeName: "A", fromFile: "Sources/Other/NoImport.swift") == nil)
        #expect(table.resolve(typeName: "Missing", fromFile: "Sources/App/Uses.swift") == nil)
        #expect(table.resolve(typeName: "A", fromFile: "Sources/App/Uses.swift")?.isolation == .mainActor)
        #expect(table.resolve(typeName: "Core.A", fromFile: "Sources/App/Uses.swift")?.isolation == .mainActor)
    }

    @Test("Several declarations that agree resolve, with their stored properties merged")
    func agreeingDeclarationsMerge() {
        let table = table([
            "Sources/M/A.swift": """
            #if os(macOS)
            @MainActor final class Screen { var width = 0 }
            #else
            @MainActor final class Screen { var height = 0 }
            #endif
            """,
        ])
        let facts = table.resolve(typeName: "Screen", fromFile: "Sources/M/A.swift")
        #expect(facts?.isolation == .mainActor)
        #expect(facts?.storedProperties == ["width", "height"])
    }

    @Test("Stored properties exclude static and nonisolated ones")
    func storedProperties() {
        let table = table(["Sources/M/A.swift": """
        @MainActor final class A {
            var stored = 0
            let constant = 1
            static var shared = 2
            // Justification: written once before any reader exists, then only read
            nonisolated(unsafe) var escape = 3
            var computed: Int { stored }
        }
        """])
        #expect(table.resolve(typeName: "A", fromFile: "Sources/M/A.swift")?.storedProperties == ["stored", "constant"])
    }
}
