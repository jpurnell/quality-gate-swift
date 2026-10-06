import Foundation
import Testing
import QualityGateCore
@testable import BuildChecker

/// A compile unit counts only if it belongs to the build that just ran.
///
/// A build directory outlives the builds that wrote it. A target that was renamed, or a variant
/// directory an older toolchain named differently
/// (`ShowcaseCLI-3E4BF3A074D2020-testable-t.build`), leaves its output file map and records
/// behind; the map still names sources that exist, so its units looked live. Nothing refreshes
/// them, so the first edit to one of those sources made the checker report
/// `build.warnings-unverified` on every run until `.build` was deleted. Reproduced with a real
/// `swift build` by renaming a target and editing a file.
///
/// The build system says which maps are its own: swiftbuild's build description
/// (`XCBuildData/<id>.xcbuilddata/manifest.json`, the last id in `prior-build-descriptions.txt`)
/// and the native build system's `<configuration>.yaml` each name the output file map of every
/// target they build. The trees here are hand-written in those shapes.
/// See `quality-gate-swift-project/plans/proposals/AWarmBuildForgetsItsWarnings.md`,
/// "Found after shipping (2026-10-06)".
@Suite("RecordedDiagnostics: compile units of a build that is gone")
struct OrphanedCompileUnitsTests {
    typealias Tree = CompileUnitIndexTests.Tree

    static let intermediates = ".build/out/Intermediates.noindex"
    static let live = "\(intermediates)/Fixture.build/Debug/Fixture-t.build/Objects-normal/arm64"
    static let orphan = "\(intermediates)/Fixture.build/Debug/Fixture-3E4BF3A074D2020-testable-t.build/Objects-normal/arm64"
    static let buildData = "\(intermediates)/XCBuildData"

    static let written = Date(timeIntervalSince1970: 1_790_000_000)
    static let recorded = Date(timeIntervalSince1970: 1_790_000_060)
    static let edited = Date(timeIntervalSince1970: 1_790_000_120)
    static let rebuilt = Date(timeIntervalSince1970: 1_790_000_180)
    static let thisRun = Date(timeIntervalSince1970: 1_790_000_240)

    /// A swiftbuild description in the shape Swift 6.4 writes: the map is named as a command's
    /// output, and again inside longer strings that are not paths.
    static func swiftbuildManifest(naming maps: [String]) throws -> Data {
        var commands: [String: Any] = [:]
        for map in maps {
            commands["P2:target-Fixture-PACKAGE-TARGET:Fixture:Debug:WriteAuxiliaryFile \(map)"] = [
                "tool": "auxiliary-file",
                "description": "WriteAuxiliaryFile \(map)",
                "inputs": ["<target-Fixture-PACKAGE-TARGET:Fixture-immediate>"],
                "outputs": [map],
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["client": ["name": "basic"], "commands": commands], options: [.sortedKeys])
    }

    /// Writes one swiftbuild build description and appends its id to the list of prior ones.
    static func describeBuild(_ tree: Tree, id: String, naming maps: [String], after earlier: [String] = []) throws {
        let directory = tree.root.appendingPathComponent("\(buildData)/\(id).xcbuilddata")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try swiftbuildManifest(naming: maps).write(to: directory.appendingPathComponent("manifest.json"))
        try tree.write("\(buildData)/prior-build-descriptions.txt", (earlier + [id]).joined(separator: "\n") + "\n")
        try tree.write(".build/.buildSystem_debug", "swiftbuild")
    }

    /// One source compiled by the live target and, once, by a variant that is no longer built.
    ///
    /// The source was edited and the live unit recompiled, so the live record is current and the
    /// orphan's — which nothing will ever rewrite — is older than the source.
    static func tree(liveRecord: Bool = true) throws -> (tree: Tree, source: String, liveMap: String, orphanMap: String) {
        let tree = try Tree()
        let source = try tree.write("Sources/Fixture/Warns.swift", modified: edited)
        try tree.writeMap("\(live)/Fixture-OutputFileMap.json", [source: ["diagnostics": tree.path("\(live)/Warns.dia")]])
        if liveRecord {
            try tree.write("\(live)/Warns.dia", modified: rebuilt)
        }
        try tree.writeMap("\(orphan)/Fixture-3E4BF3A074D2020-testable-OutputFileMap.json", [
            source: ["diagnostics": tree.path("\(orphan)/Warns.dia")],
        ])
        try tree.write("\(orphan)/Warns.dia", modified: recorded)
        return (
            tree, source,
            tree.path("\(live)/Fixture-OutputFileMap.json"),
            tree.path("\(orphan)/Fixture-3E4BF3A074D2020-testable-OutputFileMap.json")
        )
    }

    static func collect(_ tree: Tree, holding contents: [String: [Diagnostic]] = [:]) -> RecordedDiagnostics {
        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "debug")
        return RecordedDiagnostics.collect(
            index: index, projectRoot: tree.root.path, buildStarted: thisRun, read: { contents[$0] ?? [] })
    }

    // MARK: - The defect

    @Test("An orphaned variant directory beside the live one raises no warnings-unverified, and the note names it")
    func orphanedVariantIsNotUnverified() throws {
        let fixture = try Self.tree()
        defer { fixture.tree.remove() }
        try Self.describeBuild(fixture.tree, id: "b4c36ba5d301dd68a67d8efd6ab96320", naming: [fixture.liveMap])

        let recorded = Self.collect(fixture.tree)

        #expect(recorded.unverifiedDiagnostic == nil)
        #expect(recorded.coverage.unverified == [])
        #expect(recorded.coverageDiagnostic.message.contains(
            "1 Swift compile unit(s): 0 compiled by this run, 1 read from recorded diagnostics"))
        #expect(recorded.coverageDiagnostic.message.contains(
            "1 compile unit(s) in 1 output file map(s) ignored as orphaned"))
        #expect(recorded.coverage == RecordedDiagnostics.Coverage(
            mapCount: 1, unitCount: 1, compiledByThisRun: 0, readFromRecord: 1, orphanedUnits: 1, orphanedMaps: 1))

        let index = CompileUnitIndex.scan(buildDirectory: fixture.tree.buildDirectory.path, configuration: "debug")
        #expect(index.units.map(\.diagnosticsPath) == [fixture.tree.path("\(Self.live)/Warns.dia")])
        #expect(index.orphanedMaps == [fixture.orphanMap])
        #expect(index.orphanedUnitCount == 1)
    }

    @Test("An orphan's record is not read: a warning only it holds is not reported")
    func orphanRecordIsNotRead() throws {
        let fixture = try Self.tree()
        defer { fixture.tree.remove() }
        try Self.describeBuild(fixture.tree, id: "b4c36ba5d301dd68a67d8efd6ab96320", naming: [fixture.liveMap])
        // Made current, so that only being orphaned keeps it from being read.
        try FileManager.default.setAttributes(
            [.modificationDate: Self.rebuilt], ofItemAtPath: fixture.tree.path("\(Self.orphan)/Warns.dia"))

        let recorded = Self.collect(fixture.tree, holding: [
            fixture.tree.path("\(Self.orphan)/Warns.dia"): [
                Diagnostic(
                    severity: .warning, message: "result of call to 'loud()' is unused [#NoUsage]",
                    filePath: fixture.source, lineNumber: 6, columnNumber: 9, ruleId: "swift-compiler"),
            ],
        ])

        #expect(recorded.diagnostics.isEmpty)
        #expect(recorded.coverageDiagnostic.message.contains("1 Swift compile unit(s): "))
    }

    @Test("The native build system's description is read the same way")
    func nativeDescriptionNamesTheLiveMap() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let source = try tree.write("Sources/Lib/One.swift", modified: Self.edited)
        let liveMap = tree.path(".build/arm64-apple-macosx/debug/NewName.build/output-file-map.json")
        try tree.writeMap(".build/arm64-apple-macosx/debug/NewName.build/output-file-map.json", [
            source: ["diagnostics": tree.path(".build/arm64-apple-macosx/debug/NewName.build/One.dia")],
        ])
        try tree.write(".build/arm64-apple-macosx/debug/NewName.build/One.dia", modified: Self.rebuilt)
        try tree.writeMap(".build/arm64-apple-macosx/debug/OldName.build/output-file-map.json", [
            source: ["diagnostics": tree.path(".build/arm64-apple-macosx/debug/OldName.build/One.dia")],
        ])
        try tree.write(".build/arm64-apple-macosx/debug/OldName.build/One.dia", modified: Self.recorded)
        // llbuild's manifest names the map among the compile command's arguments.
        try tree.write(".build/debug.yaml", """
            commands:
              "C.NewName-arm64-apple-macosx-debug.module":
                tool: shell
                args: ["/usr/bin/swiftc","-module-name","NewName","-output-file-map","\(liveMap)","-incremental"]

            """)
        try tree.write(".build/.buildSystem_debug", "native")

        let recorded = Self.collect(tree)

        #expect(recorded.unverifiedDiagnostic == nil)
        #expect(recorded.coverageDiagnostic.message.contains(
            "1 compile unit(s) in 1 output file map(s) ignored as orphaned"))
    }

    @Test("The latest build description decides, not an earlier one that named the orphan")
    func latestDescriptionDecides() throws {
        let fixture = try Self.tree()
        defer { fixture.tree.remove() }
        try Self.describeBuild(fixture.tree, id: "13a3de501433586b81f8276de8025133", naming: [fixture.liveMap, fixture.orphanMap])
        try Self.describeBuild(
            fixture.tree, id: "b4c36ba5d301dd68a67d8efd6ab96320", naming: [fixture.liveMap],
            after: ["13a3de501433586b81f8276de8025133"])

        let recorded = Self.collect(fixture.tree)

        #expect(recorded.unverifiedDiagnostic == nil)
        #expect(recorded.coverageDiagnostic.message.contains("ignored as orphaned"))
    }

    // MARK: - What must keep warning

    @Test("A live unit whose record is missing still warns")
    func liveUnitWithAMissingRecordStillWarns() throws {
        let fixture = try Self.tree(liveRecord: false)
        defer { fixture.tree.remove() }
        try Self.describeBuild(fixture.tree, id: "b4c36ba5d301dd68a67d8efd6ab96320", naming: [fixture.liveMap])

        let recorded = Self.collect(fixture.tree)

        let finding = try #require(recorded.unverifiedDiagnostic)
        #expect(finding.ruleId == "build.warnings-unverified")
        #expect(finding.severity == .warning)
        #expect(finding.message.contains("1 of 1 compile units were up to date"))
        #expect(finding.message.contains("(first: `Sources/Fixture/Warns.swift`)"))
        #expect(recorded.coverageDiagnostic.message.contains("1 not verified"))
        #expect(recorded.coverageDiagnostic.message.contains(
            "1 compile unit(s) in 1 output file map(s) ignored as orphaned"))
    }

    @Test("Without a build description every map is live, as before: nothing is called an orphan on a guess")
    func noDescriptionMeansEveryMapIsLive() throws {
        let fixture = try Self.tree()
        defer { fixture.tree.remove() }

        let recorded = Self.collect(fixture.tree)

        #expect(recorded.coverage.unverified == ["Sources/Fixture/Warns.swift"])
        #expect(recorded.coverageDiagnostic.message.contains("2 Swift compile unit(s): "))
        #expect(!recorded.coverageDiagnostic.message.contains("orphaned"))
    }

    @Test("A description that names none of the maps on disk describes another build, and orphans nothing")
    func descriptionOfAnotherBuildOrphansNothing() throws {
        let fixture = try Self.tree()
        defer { fixture.tree.remove() }
        // The last build here was a release one: its description names Release maps only.
        try Self.describeBuild(fixture.tree, id: "33a67e7790b307f0c2fe8bbd86b17172", naming: [
            fixture.liveMap.replacingOccurrences(of: "/Debug/", with: "/Release/"),
        ])

        let recorded = Self.collect(fixture.tree)

        #expect(recorded.coverageDiagnostic.message.contains("2 Swift compile unit(s): "))
        #expect(!recorded.coverageDiagnostic.message.contains("orphaned"))
        #expect(recorded.unverifiedDiagnostic?.ruleId == "build.warnings-unverified")
    }

    @Test("An orphaned map none of whose sources is first-party is not worth a mention")
    func orphanedDependencyMapIsNotCounted() throws {
        let fixture = try Self.tree()
        defer { fixture.tree.remove() }
        try FileManager.default.removeItem(atPath: fixture.orphanMap)
        let checkout = try fixture.tree.write(".build/checkouts/Dep/Sources/Dep/Dep.swift")
        try fixture.tree.writeMap("\(Self.intermediates)/Dep.build/Debug/Dep-old-t.build/Objects-normal/arm64/Dep-OutputFileMap.json", [
            checkout: ["diagnostics": fixture.tree.path("Dep.dia")],
        ])
        try Self.describeBuild(fixture.tree, id: "b4c36ba5d301dd68a67d8efd6ab96320", naming: [fixture.liveMap])

        let recorded = Self.collect(fixture.tree)

        #expect(recorded.unverifiedDiagnostic == nil)
        #expect(!recorded.coverageDiagnostic.message.contains("orphaned"))
    }

    // MARK: - Reading a description

    @Test("Only a string that is the map's path, start to end, names it")
    func onlyAWholePathNamesAMap() throws {
        let description = Data(#"""
            {"commands":{"P2:target-A:WriteAuxiliaryFile /p/Debug/A-t.build/A-OutputFileMap.json":{
              "description":"WriteAuxiliaryFile /p/Debug/B-t.build/B-OutputFileMap.json",
              "outputs":["/p/Debug/C-t.build/C-OutputFileMap.json"],
              "args":["-output-file-map","/p/with \"quotes\"/debug/D.build/output-file-map.json","relative/E-OutputFileMap.json"]}}}
            """#.utf8)

        #expect(CurrentBuildDescription.outputFileMapPaths(in: description) == [
            "/p/Debug/C-t.build/C-OutputFileMap.json",
            "/p/with \"quotes\"/debug/D.build/output-file-map.json",
        ])
        #expect(CurrentBuildDescription.outputFileMapPaths(in: Data()) == [])
    }

    @Test("SwiftPM's marker says which build system's description is the latest build's")
    func markerChoosesTheDescription() throws {
        let fixture = try Self.tree()
        defer { fixture.tree.remove() }
        let build = fixture.tree.buildDirectory.path
        #expect(CurrentBuildDescription.descriptionPath(buildDirectory: build, configuration: "debug") == nil)

        try Self.describeBuild(fixture.tree, id: "b4c36ba5d301dd68a67d8efd6ab96320", naming: [fixture.liveMap])
        let manifest = fixture.tree.path("\(Self.buildData)/b4c36ba5d301dd68a67d8efd6ab96320.xcbuilddata/manifest.json")
        let yaml = try fixture.tree.write(".build/debug.yaml", "commands:\n", modified: Self.recorded)
        #expect(CurrentBuildDescription.descriptionPath(buildDirectory: build, configuration: "Debug") == manifest)

        try fixture.tree.write(".build/.buildSystem_debug", "native\n")
        #expect(CurrentBuildDescription.descriptionPath(buildDirectory: build, configuration: "debug") == yaml)

        // No marker — an older toolchain: whichever description was written last.
        try FileManager.default.removeItem(atPath: fixture.tree.path(".build/.buildSystem_debug"))
        #expect(CurrentBuildDescription.descriptionPath(buildDirectory: build, configuration: "debug") == manifest)
        try FileManager.default.setAttributes([.modificationDate: Date.distantFuture], ofItemAtPath: yaml)
        #expect(CurrentBuildDescription.descriptionPath(buildDirectory: build, configuration: "debug") == yaml)
    }

    @Test("A description list whose last entry is not an identifier, or names no description on disk, answers nothing")
    func unusableDescriptionListAnswersNothing() throws {
        let fixture = try Self.tree()
        defer { fixture.tree.remove() }
        let build = fixture.tree.buildDirectory.path
        // A line that leads out of the data directory, to a file that is really there.
        try fixture.tree.write("\(Self.intermediates)/escape.xcbuilddata/manifest.json", "{}")
        try fixture.tree.write("\(Self.buildData)/prior-build-descriptions.txt", "../escape\n")
        #expect(CurrentBuildDescription.swiftbuildManifest(buildDirectory: build) == nil)
        try fixture.tree.write("\(Self.buildData)/prior-build-descriptions.txt", "0123456789abcdef0123456789abcdef\n")
        #expect(CurrentBuildDescription.swiftbuildManifest(buildDirectory: build) == nil)
        #expect(CurrentBuildDescription.namedOutputFileMaps(buildDirectory: build, configuration: "debug") == nil)
    }

    @Test("A configuration name that leads out of the build directory finds no marker and no description")
    func configurationNameIsNotFollowedOutOfTheBuildDirectory() throws {
        let fixture = try Self.tree()
        defer { fixture.tree.remove() }
        let build = fixture.tree.buildDirectory.path
        // Both files are really there, one level above `.build`.
        try fixture.tree.write(".buildSystem_x", "native")
        try fixture.tree.write("outside.yaml", "commands:\n")
        try fixture.tree.write(".build/.buildSystem_debug", "native")
        try fixture.tree.write(".build/debug.yaml", "commands:\n")

        #expect(CurrentBuildDescription.buildSystem(buildDirectory: build, configuration: "debug") == "native")
        #expect(CurrentBuildDescription.buildSystem(buildDirectory: build, configuration: "x/../../x") == nil)
        #expect(CurrentBuildDescription.nativeManifest(buildDirectory: build, configuration: "debug")
            == fixture.tree.path(".build/debug.yaml"))
        #expect(CurrentBuildDescription.nativeManifest(buildDirectory: build, configuration: "../outside") == nil)
    }
}
