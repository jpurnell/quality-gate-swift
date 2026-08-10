import Foundation
import Testing
@testable import DocCodeAuditor
@testable import QualityGateCore

/// The checker's contract with the runner: identity, scheduling, gate authority, caching.
@Suite("Doc Code Auditor")
struct DocCodeAuditorTests {

    // MARK: - Identity

    @Test("Identity is the documented one")
    func identity() {
        let auditor = DocCodeAuditor()
        #expect(auditor.id == "doc-code")
        #expect(auditor.name == "Documentation Code Compiler")
    }

    // MARK: - Scheduling

    @Test("Parallel-safe, which is what puts it after the build")
    func parallelSafe() {
        // `CheckerRunner` runs every non-parallel-safe checker to completion first, then the
        // parallel-safe ones concurrently. `BuildChecker` declares itself non-parallel-safe,
        // so declaring `doc-code` parallel-safe is precisely what guarantees it reads a
        // finished `.build/debug` rather than racing `swift build` writing into it. It never
        // writes there itself — every article is typechecked in its own temporary directory.
        #expect(DocCodeAuditor().isParallelSafe)
    }

    @Test("Hermetic: the verdict is a function of the tree and the module built from it")
    func hermetic() {
        // No calendar, no network, no out-of-tree state. The one input that is not the
        // working tree — the built module — is derived from the same commit, and the
        // toolchain is folded into the cache's gate identity. The case that would otherwise
        // argue for `.external` (a module that was never built) is handled explicitly as a
        // skip, so the classification does not have to carry it.
        #expect(DocCodeAuditor().hermeticity == .hermetic)
    }

    // MARK: - Caching

    @Test("Cache inputs include the articles themselves")
    func cacheInputsIncludeArticles() throws {
        // The trap the protocol warns about: `SourceCacheInputs.wholeSource` walks `.swift`
        // files only. Relying on it alone would let an edited article reuse a cached pass —
        // the one way caching can serve a verdict that is simply wrong.
        let root = try TemporaryProject.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputs = try #require(DocCodeAuditor.cacheInputs(projectRoot: root, configuration: Configuration()))
        #expect(inputs.files.contains { $0.hasSuffix("Sources/Demo/Demo.docc/Guide.md") })
    }

    @Test("Cache inputs include the manifest, which decides the language mode")
    func cacheInputsIncludeManifest() throws {
        let root = try TemporaryProject.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputs = try #require(DocCodeAuditor.cacheInputs(projectRoot: root, configuration: Configuration()))
        #expect(inputs.files.contains { $0.hasSuffix("Package.swift") })
    }

    @Test("Cache inputs include the module the articles compile against")
    func cacheInputsIncludeBuiltModule() throws {
        // The verdict depends on the module's API surface. Sources cover it when the module
        // is rebuilt from them; the built artefacts cover the case where it is not.
        let root = try TemporaryProject.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let inputs = try #require(DocCodeAuditor.cacheInputs(projectRoot: root, configuration: Configuration()))
        #expect(inputs.files.contains { $0.hasSuffix("Sources/Demo/Demo.swift") })
        #expect(inputs.files.contains { $0.contains(".build/debug") })
    }

    // MARK: - Discovery

    @Test("Articles are discovered under every .docc catalogue, with the module they document")
    func discoversCatalogues() throws {
        let root = try TemporaryProject.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let catalogues = ArticleDiscovery.catalogues(projectRoot: root, configuration: Configuration())
        #expect(catalogues.count == 1)
        #expect(catalogues.first?.moduleName == "Demo")
        #expect(catalogues.first?.articles.count == 1)
    }

    @Test("README is discovered only when configured")
    func readmeIsOptIn() throws {
        let root = try TemporaryProject.make()
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Demo\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        var configuration = Configuration()
        #expect(!ArticleDiscovery.catalogues(projectRoot: root, configuration: configuration)
            .flatMap(\.articles).contains { $0.lastPathComponent == "README.md" })

        configuration.docCode.includeReadme = true
        #expect(ArticleDiscovery.catalogues(projectRoot: root, configuration: configuration)
            .flatMap(\.articles).contains { $0.lastPathComponent == "README.md" })
    }

    // MARK: - Skipping honestly

    @Test("A project with no catalogue is skipped, not passed")
    func noCatalogueSkips() async throws {
        let root = try TemporaryProject.make(includeCatalogue: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await DocCodeAuditor().check(
            projectRoot: root, configuration: Configuration())
        #expect(result.status == .skipped)
    }

    @Test("An unbuilt module is skipped with its reason, never reported as broken documentation")
    func unbuiltModuleSkips() async throws {
        // Without the module, every article fails with `no such module` — a flood of
        // findings about the gate's own environment, indistinguishable at a glance from
        // findings about the documentation.
        let root = try TemporaryProject.make(includeBuild: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await DocCodeAuditor().check(
            projectRoot: root, configuration: Configuration())
        #expect(result.status == .skipped)
        #expect(result.diagnostics.contains { ($0.ruleId ?? "").contains("module-unavailable") })
    }
}

/// A minimal on-disk package: a manifest, one source file, one `.docc` article, and a
/// stand-in for a built module.
enum TemporaryProject {

    static func make(includeCatalogue: Bool = true, includeBuild: Bool = true) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-code-project-\(UUID().uuidString)")
        let manager = FileManager.default

        let sources = root.appendingPathComponent("Sources/Demo")
        try manager.createDirectory(at: sources, withIntermediateDirectories: true)
        try "public struct Demo { public init() {} }\n"
            .write(to: sources.appendingPathComponent("Demo.swift"), atomically: true, encoding: .utf8)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Demo", targets: [.target(name: "Demo")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        if includeCatalogue {
            let catalogue = sources.appendingPathComponent("Demo.docc")
            try manager.createDirectory(at: catalogue, withIntermediateDirectories: true)
            try "# Guide\n\n```swift\nlet a = 1\nprint(a)\n```\n"
                .write(to: catalogue.appendingPathComponent("Guide.md"), atomically: true, encoding: .utf8)
        }

        if includeBuild {
            let modules = root.appendingPathComponent(".build/debug/Modules")
            try manager.createDirectory(at: modules, withIntermediateDirectories: true)
            try Data().write(to: modules.appendingPathComponent("Demo.swiftmodule"))
        }

        return root
    }
}
