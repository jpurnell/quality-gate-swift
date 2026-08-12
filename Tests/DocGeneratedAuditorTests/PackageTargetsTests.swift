import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// The membership source both roster generators share, tested on its own.
///
/// §8.6 of the design is the reason this is parsed rather than walked: the measuring script that
/// produced revision 1's numbers looked only under `Sources/` and reported `QualityGatePlugin`
/// as a phantom module. It was not — it lives under `Plugins/`, and `Package.swift` knew.
@Suite("Package Targets")
struct PackageTargetsTests {

    private static let manifest = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "example",
        products: [
            .library(name: "Example", targets: ["Alpha"]),
        ],
        targets: [
            .target(name: "Alpha", dependencies: ["Beta"]),
            .target(name: "Beta", dependencies: [.target(name: "Gamma")]),
            .executableTarget(name: "example-cli", dependencies: ["Alpha"]),
            .plugin(name: "ExamplePlugin", capability: .command(intent: .custom(verb: "x", description: "y"))),
            .testTarget(name: "AlphaTests", dependencies: ["Alpha"]),
        ]
    )
    """

    @Test("Every non-test target, in declaration order")
    func targetsInOrder() throws {
        let root = try TemporaryDocProject.make(packageManifest: Self.manifest)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PackageTargets.load(projectRoot: root) == [
            "Alpha", "Beta", "example-cli", "ExamplePlugin",
        ])
    }

    @Test("A test target is not a module the architecture table describes")
    func testTargetsExcluded() throws {
        let root = try TemporaryDocProject.make(packageManifest: Self.manifest)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PackageTargets.load(projectRoot: root)?.contains("AlphaTests") == false)
    }

    @Test("`.target(name:)` inside a dependencies list is a reference, not a declaration")
    func nestedDependencyIsNotATarget() throws {
        let root = try TemporaryDocProject.make(packageManifest: Self.manifest)
        defer { try? FileManager.default.removeItem(at: root) }

        // `Gamma` appears only as `.target(name: "Gamma")` inside Beta's dependencies. A visitor
        // that matched every `.target(name:)` in the file would invent a module.
        #expect(PackageTargets.load(projectRoot: root)?.contains("Gamma") == false)
    }

    @Test("A product's `targets:` list is not the package's")
    func productTargetListIsNotThePackages() throws {
        let root = try TemporaryDocProject.make(packageManifest: """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "example",
            products: [
                .library(name: "Example", targets: ["Alpha", "NotDeclaredAnywhere"]),
            ],
            targets: [
                .target(name: "Alpha"),
            ]
        )
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PackageTargets.load(projectRoot: root) == ["Alpha"])
    }

    @Test("An absent manifest yields nil, so the caller reports rather than lists nothing")
    func absentManifest() throws {
        let root = try TemporaryDocProject.make(readme: "# Readme\n")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PackageTargets.load(projectRoot: root) == nil)
    }

    @Test("A manifest with no `targets:` yields nil, not an empty package")
    func manifestWithoutTargets() throws {
        let root = try TemporaryDocProject.make(packageManifest: """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "example")
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PackageTargets.load(projectRoot: root) == nil)
    }

    @Test("The DocC abstract is the paragraph under the symbol heading, folded onto one line")
    func doccAbstract() throws {
        let root = try TemporaryDocProject.make(extras: [
            "Sources/Alpha/Alpha.docc/Alpha.md": """
            # ``Alpha``

            The first module, which does
            a thing worth saying in two lines.

            ## Overview

            Not the abstract.
            """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PackageTargets.doccAbstract(of: "Alpha", projectRoot: root)
            == "The first module, which does a thing worth saying in two lines.")
    }

    @Test("A module with no catalogue has no abstract, and says so by returning nil")
    func noDoccCatalogue() throws {
        let root = try TemporaryDocProject.make(extras: ["Sources/Alpha/Alpha.swift": "// nothing\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PackageTargets.doccAbstract(of: "Alpha", projectRoot: root) == nil)
    }

    @Test("A catalogue whose article is only a heading has no abstract")
    func headingOnlyCatalogue() throws {
        let root = try TemporaryDocProject.make(extras: [
            "Sources/Alpha/Alpha.docc/Alpha.md": "# ``Alpha``\n\n## Overview\n\nText.\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PackageTargets.doccAbstract(of: "Alpha", projectRoot: root) == nil)
    }

    @Test("A plugin's catalogue is found under Plugins/, which is why the walk was wrong")
    func pluginCatalogue() throws {
        let root = try TemporaryDocProject.make(extras: [
            "Plugins/ExamplePlugin/ExamplePlugin.docc/ExamplePlugin.md": """
            # ``ExamplePlugin``

            Runs the gate from SPM.
            """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PackageTargets.doccAbstract(of: "ExamplePlugin", projectRoot: root)
            == "Runs the gate from SPM.")
    }
}
