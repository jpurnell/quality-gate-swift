import Foundation
import Testing
@testable import DocLinter

@Suite("DeclaredTypes")
struct DeclaredTypesTests {

    private let wanted: Set<String> = ["Result", "Error", "Task"]

    /// The motivating shape: a `Result` nested inside another type, which is what
    /// makes a bare link ambiguous rather than merely shadowing.
    @Test("A nested type is qualified by what encloses it")
    func nestedTypeQualified() {
        let source = """
            public struct GitProvenance {
                public struct Result: Sendable {
                    let value: Int
                }
            }
            """
        let found = DeclaredTypes.colliding(in: source, moduleName: "Core", names: wanted)
        #expect(found["Result"] == "GitProvenance/Result")
    }

    /// A top-level collision is qualified by its module — still the thing a reader
    /// has to write to disambiguate.
    @Test("A top-level type is qualified by its module")
    func topLevelQualifiedByModule() {
        let found = DeclaredTypes.colliding(
            in: "public enum Error: Swift.Error { case boom }",
            moduleName: "IndexStoreInfra", names: wanted)
        #expect(found["Error"] == "IndexStoreInfra/Error")
    }

    @Test("Names outside the wanted set are ignored")
    func ignoresUnwantedNames() {
        let found = DeclaredTypes.colliding(
            in: "struct ForecastErrorMetrics {}", moduleName: "M", names: wanted)
        #expect(found.isEmpty)
    }

    /// The reason this reads the tree rather than matching lines. Every one of these
    /// would satisfy a `^\s*struct Result` scan and none of them declares anything.
    @Test("A declaration inside a string literal is not a declaration")
    func ignoresStringLiterals() {
        let source = #"""
            let fixture = """
                struct Result {}
                """
            """#
        #expect(DeclaredTypes.colliding(in: source, moduleName: "M", names: wanted).isEmpty)
    }

    @Test("A declaration inside a comment is not a declaration")
    func ignoresComments() {
        let source = """
            // struct Result {}
            /// Documents the shape: `struct Error {}`
            let x = 1
            """
        #expect(DeclaredTypes.colliding(in: source, moduleName: "M", names: wanted).isEmpty)
    }

    @Test("Enums, classes, actors, protocols and typealiases all count")
    func everyDeclarationKind() {
        for (keyword, body) in [("enum", "case a"), ("final class", ""), ("actor", ""),
                                ("protocol", "")] {
            let found = DeclaredTypes.colliding(
                in: "\(keyword) Task { \(body) }", moduleName: "M", names: wanted)
            #expect(found["Task"] == "M/Task", "\(keyword) was not recorded")
        }
        let alias = DeclaredTypes.colliding(
            in: "typealias Task = Int", moduleName: "M", names: wanted)
        #expect(alias["Task"] == "M/Task")
    }

    /// Deterministic: the first declaration wins, so a package with two `Result`
    /// types produces the same map whatever order files arrive in.
    @Test("The first declaration wins")
    func firstDeclarationWins() {
        let source = """
            struct Outer { struct Result {} }
            struct Later { struct Result {} }
            """
        #expect(DeclaredTypes.colliding(
            in: source, moduleName: "M", names: wanted)["Result"] == "Outer/Result")
    }

    @Test("Module name is derived from the Sources path")
    func moduleFromPath() {
        let url = URL(fileURLWithPath: "/p/Sources/QualityGateCore/GitProvenance.swift")
        #expect(DeclaredTypes.moduleName(of: url, spelling: "Sources") == "QualityGateCore")
    }
}
