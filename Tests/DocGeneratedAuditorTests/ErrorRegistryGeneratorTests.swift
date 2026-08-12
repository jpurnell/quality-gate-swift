import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// Generator tests, kept separate from checker tests so a generator defect is
/// distinguishable from a comparison defect.
@Suite("Error Registry Generator")
struct ErrorRegistryGeneratorTests {

    private static let errorEnum = """
    import Foundation

    /// Errors that can occur during quality gate execution.
    public enum QualityGateError: Error, Sendable {

        /// Swift build failed with the given exit code and output.
        case buildFailed(exitCode: Int32, output: String)

        /// One or more tests failed.
        case testsFailed(count: Int)

        /// A foreign-mode run attempted to write inside the analyzed repository
        /// (Phase 1 WriteGuard — the Maintainer's Promise, enforced).
        case writeGuardViolation(path: String)
    }
    """

    private static func project(_ contents: String = errorEnum) throws -> URL {
        try TemporaryDocProject.make(
            extras: ["Sources/QualityGateCore/QualityGateError.swift": contents])
    }

    @Test("Identity: the id in the delimiters, and a source a reader can go and check")
    func identity() {
        let generator = ErrorRegistryGenerator()
        #expect(generator.id == "error-registry")
        #expect(generator.derivedFrom.contains("QualityGateError"))
    }

    @Test("One row per case, in declaration order, with the module it is declared in")
    func rowsPerCase() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ErrorRegistryGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Configuration())

        #expect(body.lines.count == 3)
        #expect(body.lines[0] == "| `QualityGateError.buildFailed` | QualityGateCore | Swift build failed with the given exit code and output. |")
        #expect(body.lines[2].contains("writeGuardViolation"))
    }

    @Test("A multi-line abstract folds onto one line, because a table cell has no line break")
    func multiLineAbstract() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ErrorRegistryGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Configuration())

        #expect(body.lines[2] == "| `QualityGateError.writeGuardViolation` | QualityGateCore | A foreign-mode run attempted to write inside the analyzed repository (Phase 1 WriteGuard — the Maintainer's Promise, enforced). |")
    }

    @Test("No `Added` column: a version cannot be derived, and a derived column that cannot be is wrong")
    func noVersionColumn() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ErrorRegistryGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Configuration())

        #expect(body.lines.allSatisfy { $0.filter { $0 == "|" }.count == 4 })
        #expect(!body.contains("v1.0"))
    }

    @Test("A case with no abstract gets a visible placeholder, not an empty cell")
    func missingAbstract() throws {
        let root = try Self.project("""
        public enum QualityGateError: Error {
            case undocumented(String)
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ErrorRegistryGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Configuration())

        #expect(body.contains("needs a `///` abstract"))
    }

    @Test("The current body is ignored: every column here is derived, so drift is drift")
    func currentBodyIsIgnored() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let generator = ErrorRegistryGenerator()
        let fromEmpty = try generator.generate(
            projectRoot: root, currentBody: "", configuration: Configuration())
        let fromStale = try generator.generate(
            projectRoot: root, currentBody: "| whatever | Core | nonsense |",
            configuration: Configuration())

        #expect(fromEmpty == fromStale)
    }

    @Test("An absent enum is ungeneratable — reported, never silently skipped")
    func absentEnumThrows() throws {
        let root = try TemporaryDocProject.make(
            extras: ["Sources/Other/Other.swift": "public struct Other {}\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: RegionGeneratorError.self) {
            try ErrorRegistryGenerator().generate(
                projectRoot: root, currentBody: "", configuration: Configuration())
        }
    }

    @Test("The registry enumerates the binary's generators, and can be asked for one by id")
    func registry() {
        #expect(RegionGeneratorRegistry.ids.contains("error-registry"))
        #expect(RegionGeneratorRegistry.generator(for: "error-registry")?.id == "error-registry")
        #expect(RegionGeneratorRegistry.generator(for: "no-such-id") == nil)
        // Ids are unique, or "the" generator for an id would not be a well-defined thing.
        #expect(Set(RegionGeneratorRegistry.ids).count == RegionGeneratorRegistry.ids.count)
    }
}
