import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// The architecture table a new contributor reads first, and an agent reads at session start.
@Suite("Module Structure Generator")
struct ModuleStructureGeneratorTests {

    private static let manifest = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "example",
        targets: [
            .target(name: "Alpha"),
            .target(name: "Beta"),
            .plugin(name: "ExamplePlugin", capability: .command(intent: .custom(verb: "x", description: "y"))),
            .testTarget(name: "AlphaTests", dependencies: ["Alpha"]),
        ]
    )
    """

    private static func project(extras: [String: String] = [:]) throws -> URL {
        try TemporaryDocProject.make(packageManifest: manifest, extras: extras)
    }

    @Test("Identity: the id in the delimiters, and a source a reader can go and check")
    func identity() {
        let generator = ModuleStructureGenerator()
        #expect(generator.id == "module-structure")
        #expect(generator.derivedFrom.contains("Package.swift"))
    }

    @Test("One line per non-test target, in declaration order, including one under Plugins/")
    func linePerTarget() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ModuleStructureGenerator().generate(
            projectRoot: root, currentBody: "", configuration: TemporaryDocProject.configuration())

        #expect(body.lines.count == 3)
        #expect(body.lines[0].hasPrefix("- `Alpha` —"))
        #expect(body.lines[2].hasPrefix("- `ExamplePlugin` —"))
        #expect(!body.contains("AlphaTests"))
    }

    @Test("A module's description comes from its DocC abstract when it has one")
    func descriptionFromDocC() throws {
        let root = try Self.project(extras: [
            "Sources/Alpha/Alpha.docc/Alpha.md": "# ``Alpha``\n\nDoes the first thing.\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ModuleStructureGenerator().generate(
            projectRoot: root, currentBody: "", configuration: TemporaryDocProject.configuration())

        #expect(body.lines[0] == "- `Alpha` — Does the first thing.")
    }

    @Test("A module with no catalogue gets a visible placeholder, not a blank")
    func placeholderWithoutDocC() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ModuleStructureGenerator().generate(
            projectRoot: root, currentBody: "", configuration: TemporaryDocProject.configuration())

        #expect(body.lines[0].contains("needs a description"))
    }

    @Test("A description already written is preserved, even against a later DocC abstract")
    func existingDescriptionIsPreserved() throws {
        // The abstract supplies what nobody has written yet; it does not overwrite what someone
        // has. §7's rule that the tie does not automatically go to the machine, applied to the
        // one column a human curated.
        let root = try Self.project(extras: [
            "Sources/Alpha/Alpha.docc/Alpha.md": "# ``Alpha``\n\nThe abstract, written later.\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ModuleStructureGenerator().generate(
            projectRoot: root, currentBody: "- `Alpha` — the description someone wrote",
            configuration: TemporaryDocProject.configuration())

        #expect(body.lines[0] == "- `Alpha` — the description someone wrote")
    }

    @Test("A line for a module that is no longer a target is dropped")
    func departedModuleIsDropped() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ModuleStructureGenerator().generate(
            projectRoot: root, currentBody: "- `Deleted` — a module that was removed",
            configuration: TemporaryDocProject.configuration())

        #expect(!body.contains("Deleted"))
    }

    @Test("No manifest is ungeneratable — an empty architecture is not a finding, it is a bug")
    func absentManifestThrows() throws {
        let root = try TemporaryDocProject.make(readme: "# Readme\n")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: RegionGeneratorError.self) {
            try ModuleStructureGenerator().generate(
                projectRoot: root, currentBody: "",
                configuration: TemporaryDocProject.configuration())
        }
    }

    @Test("Regenerating its own output changes nothing")
    func idempotent() throws {
        let root = try Self.project(extras: [
            "Sources/Alpha/Alpha.docc/Alpha.md": "# ``Alpha``\n\nDoes the first thing.\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let generator = ModuleStructureGenerator()
        let configuration = TemporaryDocProject.configuration()
        let once = try generator.generate(
            projectRoot: root, currentBody: "", configuration: configuration)
        let twice = try generator.generate(
            projectRoot: root, currentBody: once, configuration: configuration)

        #expect(once == twice)
    }

    @Test("The registry can be asked for this generator by the id in the delimiters")
    func registered() {
        #expect(RegionGeneratorRegistry.generator(for: "module-structure")?.id == "module-structure")
    }
}
