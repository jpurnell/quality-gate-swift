import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// The checklist whose membership is derived and whose tick-boxes are emphatically not.
@Suite("Status Roster Generator")
struct StatusRosterGeneratorTests {

    private static let manifest = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "example",
        targets: [
            .target(name: "Alpha"),
            .target(name: "Beta"),
            .testTarget(name: "AlphaTests", dependencies: ["Alpha"]),
        ]
    )
    """

    private static func project(extras: [String: String] = [:]) throws -> URL {
        try TemporaryDocProject.make(packageManifest: manifest, extras: extras)
    }

    @Test("Identity: the id in the delimiters, and a source a reader can go and check")
    func identity() {
        let generator = StatusRosterGenerator()
        #expect(generator.id == "status-roster")
        #expect(generator.derivedFrom.contains("Package.swift"))
    }

    @Test("A new module arrives unchecked: nothing derives whether the work is done")
    func newModuleArrivesUnchecked() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try StatusRosterGenerator().generate(
            projectRoot: root, currentBody: "", configuration: TemporaryDocProject.configuration())

        #expect(body.lines.count == 2)
        #expect(body.lines.allSatisfy { $0.hasPrefix("- [ ] ") })
    }

    @Test("A ticked box stays ticked, because the generator owns membership and not state")
    func tickBoxIsNeverFlipped() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try StatusRosterGenerator().generate(
            projectRoot: root, currentBody: "- [x] Alpha — done, with 200 tests",
            configuration: TemporaryDocProject.configuration())

        #expect(body.lines[0] == "- [x] Alpha — done, with 200 tests")
        #expect(body.lines[1].hasPrefix("- [ ] Beta"))
    }

    @Test("An unticked box stays unticked even when the module plainly exists")
    func existenceIsNotCompletion() throws {
        // The trap this split exists to avoid: `Beta` is a real target, and deriving `- [x]`
        // from that would make the checklist assert work is finished on the evidence that a
        // directory is present.
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try StatusRosterGenerator().generate(
            projectRoot: root, currentBody: "- [ ] Beta — half written",
            configuration: TemporaryDocProject.configuration())

        #expect(body.contains("- [ ] Beta — half written"))
    }

    @Test("A line naming something that is not a target is dropped, and reported as such")
    func nonTargetLineIsDropped() throws {
        // `XcodeReporter` is this repository's real case: a type inside `QualityGateCore` with
        // a line in a roster of modules. Dropping it here is a claim the reader gets to
        // overrule — the finding says "or fix the source if the generator is the one that is
        // wrong" precisely because §8.5 is what happens when it does not.
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try StatusRosterGenerator().generate(
            projectRoot: root, currentBody: "- [ ] XcodeReporter — `--format xcode`",
            configuration: TemporaryDocProject.configuration())

        #expect(!body.contains("XcodeReporter"))
    }

    @Test("A struck line survives, because deleting it destroys the record of where it went")
    func struckLineSurvives() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try StatusRosterGenerator().generate(
            projectRoot: root,
            currentBody: "- [x] ~~DiskCleaner~~ — became the `clean` subcommand",
            configuration: TemporaryDocProject.configuration())

        #expect(body.contains("~~DiskCleaner~~"))
    }

    @Test("A new module's description comes from its DocC abstract when it has one")
    func descriptionFromDocC() throws {
        let root = try Self.project(extras: [
            "Sources/Beta/Beta.docc/Beta.md": "# ``Beta``\n\nThe second module.\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try StatusRosterGenerator().generate(
            projectRoot: root, currentBody: "", configuration: TemporaryDocProject.configuration())

        #expect(body.contains("- [ ] Beta — The second module."))
    }

    @Test("No manifest is ungeneratable, not a roster of nothing")
    func absentManifestThrows() throws {
        let root = try TemporaryDocProject.make(readme: "# Readme\n")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: RegionGeneratorError.self) {
            try StatusRosterGenerator().generate(
                projectRoot: root, currentBody: "",
                configuration: TemporaryDocProject.configuration())
        }
    }

    @Test("Regenerating its own output changes nothing")
    func idempotent() throws {
        let root = try Self.project()
        defer { try? FileManager.default.removeItem(at: root) }

        let generator = StatusRosterGenerator()
        let configuration = TemporaryDocProject.configuration()
        let once = try generator.generate(
            projectRoot: root, currentBody: "- [x] Alpha — done", configuration: configuration)
        let twice = try generator.generate(
            projectRoot: root, currentBody: once, configuration: configuration)

        #expect(once == twice)
    }

    @Test("The registry can be asked for this generator by the id in the delimiters")
    func registered() {
        #expect(RegionGeneratorRegistry.generator(for: "status-roster")?.id == "status-roster")
    }
}
