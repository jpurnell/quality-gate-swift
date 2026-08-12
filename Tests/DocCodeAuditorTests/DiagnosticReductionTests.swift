import Foundation
import Testing
@testable import DocCodeAuditor
@testable import QualityGateCore

/// The reduction from raw compiler output to a verdict.
///
/// Every test here exists because the checker once reported PASSED for a catalogue in which
/// it had typechecked nothing: the compiler's fatal diagnostic carried no source location,
/// the parser required one, and the error was dropped on the floor.
@Suite("Doc Code: diagnostic reduction")
struct DiagnosticReductionTests {

    // MARK: - Nothing fatal may be silent

    @Test("An error the compiler could not locate becomes a barrier")
    func unlocatableErrorBecomesBarrier() {
        // `<unknown>:0:` has two colon-fields, so no line number can be recovered. An error
        // that cannot be attached to a line of the assembled program is not a statement
        // about a line of the article — it is a statement about whether the article could
        // be read at all. That is what a barrier is.
        let output = "<unknown>:0: error: missing required module '_SwiftSyntaxCShims'"
        let reduced = ArticleAuditor.reduce(output: output)
        #expect(reduced.barrier == "missing required module '_SwiftSyntaxCShims'")
    }

    @Test("An unlocatable error is never reduced to silence")
    func unlocatableErrorIsNeverSilent() {
        // The exact shape of the defect: `(errors: [], barrier: nil)` is indistinguishable
        // from a clean article, and `ArticleVerdict.passed` reads it as one.
        let output = "<unknown>:0: error: missing required module 'CYaml'"
        let reduced = ArticleAuditor.reduce(output: output)
        #expect(!(reduced.errors.isEmpty && reduced.barrier == nil))
    }

    @Test("Every fatal phrasing is a barrier, not only 'no such module'")
    func everyFatalPhrasingIsABarrier() {
        // The original test was a single `hasPrefix("no such module")`. The compiler has at
        // least four ways to say it could not proceed, and the one this package produces
        // was not the one being matched.
        let phrasings = [
            "missing required module 'CYaml'",
            "could not build C module 'CLMDB'",
            "could not build Objective-C module 'IndexStoreDB_CIndexStoreDB'",
            "unable to load standard library for target 'arm64-apple-macosx15.0'",
        ]
        for phrasing in phrasings {
            let reduced = ArticleAuditor.reduce(output: "<unknown>:0: error: \(phrasing)")
            #expect(reduced.barrier == phrasing, "\(phrasing) should be a barrier")
        }
    }

    @Test("'no such module' stays a barrier even though it carries a location")
    func noSuchModuleStaysABarrier() {
        // This one *does* name the import line, so without the explicit check it would be
        // filed as an ordinary compile error — sending the reader to fix line 3 of an
        // article whose real problem is the build.
        let output = "/tmp/doc-code-x/main.swift:3:8: error: no such module 'MyChecker'"
        let reduced = ArticleAuditor.reduce(output: output)
        #expect(reduced.barrier == "no such module 'MyChecker'")
    }

    // MARK: - Behaviour that must not regress

    @Test("One error per source line; the rest are cascade")
    func firstErrorPerLineIsKept() {
        // A single unresolved identifier produces a dozen downstream complaints, and
        // reporting all of them makes the article look far worse than the repair is.
        let output = """
            /tmp/doc-code-x/main.swift:12:5: error: cannot find 'q1' in scope
            /tmp/doc-code-x/main.swift:12:9: error: type of expression is ambiguous
            /tmp/doc-code-x/main.swift:14:5: error: cannot find 'q2' in scope
            """
        let reduced = ArticleAuditor.reduce(output: output)
        #expect(reduced.errors.count == 2)
        #expect(reduced.errors.map(\.line) == [12, 14])
        #expect(reduced.errors.first?.message == "cannot find 'q1' in scope")
    }

    @Test("Warnings and notes are not errors")
    func onlyErrorsAreCollected() {
        let output = """
            /tmp/doc-code-x/main.swift:4:1: warning: variable 'x' was never used
            /tmp/doc-code-x/main.swift:9:1: note: did you mean 'y'?
            """
        let reduced = ArticleAuditor.reduce(output: output)
        #expect(reduced.errors.isEmpty)
        #expect(reduced.barrier == nil)
    }

    @Test("Clean output reduces to a clean verdict")
    func cleanOutputIsClean() {
        let reduced = ArticleAuditor.reduce(output: "")
        #expect(reduced.errors.isEmpty)
        #expect(reduced.barrier == nil)
    }

    @Test("The first barrier is kept, not the last")
    func firstBarrierWins() {
        // Everything behind a barrier is not a measurement of the documentation, so the
        // one worth naming is the one that stopped the compilation.
        let output = """
            <unknown>:0: error: missing required module '_SwiftSyntaxCShims'
            <unknown>:0: error: missing required module 'CYaml'
            """
        let reduced = ArticleAuditor.reduce(output: output)
        #expect(reduced.barrier == "missing required module '_SwiftSyntaxCShims'")
    }
}

/// Resolving the C-target modulemaps the built modules depend on.
@Suite("Doc Code: header search paths")
struct HeaderSearchPathTests {

    @Test("A checkout's C-target include directory is found")
    func headerSearchPathsFindCheckoutModulemaps() throws {
        // `DocCodeAuditOptions.headerSearchPaths` was declared, threaded into swiftc as
        // `-Xcc -I<path>`, and populated by nobody — which is why every module that
        // transitively depends on SwiftSyntax failed to import.
        let root = try CheckoutFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = DocCodeAuditor.headerSearchPaths(projectRoot: root, configuration: Configuration())
        #expect(paths.contains { $0.hasSuffix("Sources/_DemoCShims/include") })
    }

    @Test("An include directory with no modulemap is not offered to clang")
    func includeWithoutModulemapIsSkipped() throws {
        let root = try CheckoutFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = DocCodeAuditor.headerSearchPaths(projectRoot: root, configuration: Configuration())
        #expect(!paths.contains { $0.hasSuffix("Sources/DemoNoModulemap/include") })
    }

    @Test("Configured paths are additive, never a replacement")
    func headerSearchPathsAreAdditive() throws {
        // A knob that could *narrow* the search would be a suppression by another name.
        let root = try CheckoutFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        var configuration = Configuration()
        configuration.docCode.headerSearchPaths = ["/opt/vendor/include"]

        let paths = DocCodeAuditor.headerSearchPaths(projectRoot: root, configuration: configuration)
        #expect(paths.contains("/opt/vendor/include"))
        #expect(paths.contains { $0.hasSuffix("Sources/_DemoCShims/include") })
    }

    @Test("A `Source/` (singular) checkout is found — the layout that hid 15 errors behind 7 barriers")
    func singularSourceLayoutIsFound() throws {
        // `Sources` was hardcoded, so `mlx-swift`'s `Source/Cmlx/include` was invisible and
        // every fence importing the module stopped at a barrier. The barrier machinery worked;
        // the path derivation feeding it under-reached. A user following the diagnostic's
        // advice would have added `import Cmlx` to a doc comment about a background modifier.
        let root = try CheckoutFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = DocCodeAuditor.headerSearchPaths(projectRoot: root, configuration: Configuration())
        #expect(paths.contains { $0.hasSuffix("Source/DemoCmlx/include") })
    }

    @Test("A `src/` checkout is found")
    func lowercaseSrcLayoutIsFound() throws {
        let root = try CheckoutFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = DocCodeAuditor.headerSearchPaths(projectRoot: root, configuration: Configuration())
        #expect(paths.contains { $0.hasSuffix("src/DemoCLib") })
    }

    @Test("All three spellings contribute at once, with no duplicates")
    func everySpellingContributesExactlyOnce() throws {
        let root = try CheckoutFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = DocCodeAuditor.headerSearchPaths(projectRoot: root, configuration: Configuration())
        #expect(paths.contains { $0.hasSuffix("Sources/_DemoCShims/include") })
        #expect(paths.contains { $0.hasSuffix("Source/DemoCmlx/include") })
        #expect(paths.contains { $0.hasSuffix("src/DemoCLib") })
        #expect(Set(paths).count == paths.count)
    }

    @Test("A system-library target keeps its modulemap beside the sources, not under include/")
    func systemLibraryModulemapIsFound() throws {
        // `SwiftMCPServer/Sources/CSQLite/module.modulemap` is this shape. Requiring an
        // `include/` directory missed it, and the article that imported it stopped at
        // `missing required module 'CSQLite'`.
        let root = try CheckoutFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = DocCodeAuditor.headerSearchPaths(projectRoot: root, configuration: Configuration())
        #expect(paths.contains { $0.hasSuffix("Sources/DemoSystemLibrary") })
    }

    @Test("A project with no checkouts yields the configured paths and nothing else")
    func noCheckoutsIsNotAnError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-code-bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(DocCodeAuditor.headerSearchPaths(projectRoot: root, configuration: Configuration()).isEmpty)
    }
}

/// Modulemaps SwiftPM generates for a C target that does not ship one.
@Suite("Doc Code: generated modulemaps")
struct GeneratedModuleMapTests {

    @Test("Modulemaps generated by the Swift Build engine are collected")
    func swiftBuildLayoutIsCollected() throws {
        // A C target with no hand-written modulemap gets one generated, and it is reached by
        // `-fmodule-map-file=` rather than by a header search path — the umbrella header
        // inside it is an absolute path. `CNIOAtomics` is this shape, and an article
        // importing it stopped dead until these were passed.
        let root = try CheckoutFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let maps = DocCodeAuditor.generatedModuleMaps(projectRoot: root)
        #expect(maps.contains { $0.hasSuffix("GeneratedModuleMaps/DemoGenerated.modulemap") })
    }

    @Test("Modulemaps generated by the classic llbuild layout are collected")
    func classicLayoutIsCollected() throws {
        // `.build/debug/<Target>.build/module.modulemap`. Both layouts are accepted for the
        // same reason `ArticleDiscovery.moduleSearchPath` accepts both: which one is on disk
        // is a property of the SwiftPM version, not of the project.
        let root = try CheckoutFixture.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let maps = DocCodeAuditor.generatedModuleMaps(projectRoot: root)
        #expect(maps.contains { $0.hasSuffix("DemoClassic.build/module.modulemap") })
    }

    @Test("A project with neither layout yields nothing, not an error")
    func neitherLayoutIsNotAnError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-code-bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(DocCodeAuditor.generatedModuleMaps(projectRoot: root).isEmpty)
    }
}

/// A `.build` tree shaped like SwiftPM's, carrying every modulemap shape the checker has to
/// find: a C target with a hand-written modulemap under `include/`, a system-library target
/// with one beside its sources, a target with headers but no modulemap, and generated
/// modulemaps in both the Swift Build and classic llbuild locations.
enum CheckoutFixture {

    static func make() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-code-checkouts-\(UUID().uuidString)")
        let manager = FileManager.default

        let withMap = root.appendingPathComponent(".build/checkouts/demo-syntax/Sources/_DemoCShims/include")
        try manager.createDirectory(at: withMap, withIntermediateDirectories: true)
        try "module _DemoCShims { header \"shim.h\" export * }\n"
            .write(to: withMap.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)

        let systemLibrary = root.appendingPathComponent(".build/checkouts/demo-mcp/Sources/DemoSystemLibrary")
        try manager.createDirectory(at: systemLibrary, withIntermediateDirectories: true)
        try "module DemoSystemLibrary [system] { header \"shim.h\" export * }\n"
            .write(to: systemLibrary.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)

        let withoutMap = root.appendingPathComponent(".build/checkouts/demo-syntax/Sources/DemoNoModulemap/include")
        try manager.createDirectory(at: withoutMap, withIntermediateDirectories: true)
        try "// no modulemap here\n"
            .write(to: withoutMap.appendingPathComponent("header.h"), atomically: true, encoding: .utf8)

        // SwiftPM does not require the directory to be called `Sources`. `mlx-swift` — a real
        // dependency of a real consumer — uses `Source`, singular, and C-heavy packages wrapped
        // for SwiftPM sometimes use `src`.
        let singular = root.appendingPathComponent(".build/checkouts/demo-mlx/Source/DemoCmlx/include")
        try manager.createDirectory(at: singular, withIntermediateDirectories: true)
        try "module DemoCmlx { header \"mlx.h\" export * }\n"
            .write(to: singular.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)

        let lowercaseSrc = root.appendingPathComponent(".build/checkouts/demo-clib/src/DemoCLib")
        try manager.createDirectory(at: lowercaseSrc, withIntermediateDirectories: true)
        try "module DemoCLib { header \"clib.h\" export * }\n"
            .write(to: lowercaseSrc.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)

        let generated = root.appendingPathComponent(".build/out/Intermediates.noindex/GeneratedModuleMaps")
        try manager.createDirectory(at: generated, withIntermediateDirectories: true)
        try "module DemoGenerated { umbrella header \"/tmp/DemoGenerated.h\" export * }\n"
            .write(to: generated.appendingPathComponent("DemoGenerated.modulemap"), atomically: true, encoding: .utf8)

        let classic = root.appendingPathComponent(".build/debug/DemoClassic.build")
        try manager.createDirectory(at: classic, withIntermediateDirectories: true)
        try "module DemoClassic { umbrella header \"/tmp/DemoClassic.h\" export * }\n"
            .write(to: classic.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)

        return root
    }
}

/// The manifest API's availability domain.
@Suite("Doc Code: manifest API availability")
struct ManifestAPIAvailabilityTests {

    @Test("The tools-version is passed as the package-description version")
    func toolsVersionSetsTheAvailabilityDomain() {
        // `PackageDescription`'s surface is gated on `@available(_PackageDescription 5.5)`
        // and friends. That domain is empty unless this flag sets it, so a documented
        // `.package(url:branch:)` reads as *unavailable* — a fact about how the manifest API
        // is versioned rather than a defect in the documentation.
        let manifest = """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(name: "Demo", targets: [.target(name: "Demo")])
            """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "Demo")
        #expect(mode.flags.contains("-package-description-version"))
        #expect(mode.flags.contains("6.2"))
    }

    @Test("A manifest with no tools-version does not invent one")
    func noToolsVersionNoFlag() {
        // Guessing the domain would be worse than leaving it empty: it would silently decide
        // which manifest APIs the documentation is allowed to mention.
        let manifest = """
            import PackageDescription
            let package = Package(name: "Demo", targets: [.target(name: "Demo")])
            """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "Demo")
        #expect(!mode.flags.contains("-package-description-version"))
    }
}
