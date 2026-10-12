import Foundation
import Testing
@testable import BuildChecker

/// Tests of the output-file-map index against synthetic build directories.
///
/// Every tree here is hand-written in the shape Swift 6.4 was observed to produce — the
/// `swiftbuild` layout (`out/Intermediates.noindex/<Pkg>.build/<Config>/<Target>-t.build/
/// Objects-normal/<arch>/<Target>-OutputFileMap.json`) and the native one
/// (`<triple>/<config>/<Target>.build/output-file-map.json`) — so the index is exercised
/// without a toolchain. The end-to-end suite runs the real one.
/// See `quality-gate-swift-project/plans/proposals/AWarmBuildForgetsItsWarnings.md` §5, 12–17.
@Suite("CompileUnitIndex")
struct CompileUnitIndexTests {

    /// A scratch package root with a `.build` directory and helpers to populate both.
    struct Tree {
        let root: URL
        var buildDirectory: URL { root.appendingPathComponent(".build") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("qg-unit-index-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        }

        func remove() {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("could not remove \(root.path): \(error)")
            }
        }

        /// Writes a file under the package root and returns its absolute path.
        @discardableResult
        func write(_ relativePath: String, _ contents: String = "", modified: Date? = nil) throws -> String {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
            return url.path
        }

        /// The absolute path of a file under the package root, whether or not it exists.
        func path(_ relativePath: String) -> String {
            root.appendingPathComponent(relativePath).path
        }

        /// Writes an output file map from `[source: [kind: path]]`.
        func writeMap(_ relativePath: String, _ entries: [String: [String: String]]) throws {
            let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    static let swiftbuildObjects = ".build/out/Intermediates.noindex/Fixture.build/Debug/Fixture-t.build/Objects-normal/arm64"
    static let swiftbuildReleaseObjects = ".build/out/Intermediates.noindex/Fixture.build/Release/Fixture-t.build/Objects-normal/arm64"
    static let nativeObjects = ".build/arm64-apple-macosx/debug/Fixture.build"

    /// swiftbuild on Linux, copied from a 6.4 container rather than imagined.
    ///
    /// The configuration component is `Release-linux-x86_64`, not `Release`. Every other
    /// fixture here names a Darwin configuration directory, which is why none of them could
    /// fail the way the Linux legs did.
    static let swiftbuildLinuxReleaseObjects =
        ".build/out/Intermediates.noindex/Fixture.build/Release-linux-x86_64/Fixture-t.build/Objects-normal/x86_64"

    // MARK: - native whole-module

    /// The native build system's output file map is the same shape in both modes.
    ///
    /// Under whole-module (any release build, and what Linux 6.2 runs) the map still gives every
    /// source a `diagnostics` entry, and those records are never written: the compiler writes one
    /// `<Module>.dia` that the map does not name at all. Measured on macOS 6.4 with
    /// `--build-system native -c release`, where the only record on disk was `Fixture.dia`, 812
    /// bytes, naming `Warns.swift`. Reading the mode off the map is therefore impossible — the
    /// debug map differs only in that its per-file records exist.
    ///
    /// See `quality-gate-swift-project/plans/proposals/TheMapCannotTellYouWhichModeRan.md`.
    static let nativeReleaseObjects = ".build/arm64-apple-macosx/release/Fixture.build"

    @Test("Whole-module native: the unnamed module record is used when the named ones are absent")
    func nativeWholeModuleRecordIsFound() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let warns = try tree.write("Sources/Fixture/Warns.swift")
        let clean = try tree.write("Sources/Fixture/Clean.swift")
        let objects = Self.nativeReleaseObjects
        // The map names per-file records, exactly as the native release map does…
        try tree.writeMap("\(objects)/output-file-map.json", [
            warns: ["diagnostics": tree.path("\(objects)/Warns.dia")],
            clean: ["diagnostics": tree.path("\(objects)/Clean.dia")],
        ])
        // …none of which the whole-module build writes. This is the one it does write.
        try tree.write("\(objects)/Fixture.dia", "record")

        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "release")

        #expect(index.units.count == 1)
        #expect(index.units.first?.source == nil)
        #expect(index.units.first?.diagnosticsPath.hasSuffix("Fixture.dia") == true)
        #expect(index.units.first?.siblings.sorted() == [clean, warns].sorted())
    }

    @Test("Per-file native: records that exist are used, and no module record is substituted")
    func nativePerFileRecordsAreLeftAlone() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let warns = try tree.write("Sources/Fixture/Warns.swift")
        let clean = try tree.write("Sources/Fixture/Clean.swift")
        let objects = Self.nativeReleaseObjects
        try tree.writeMap("\(objects)/output-file-map.json", [
            warns: ["diagnostics": tree.path("\(objects)/Warns.dia")],
            clean: ["diagnostics": tree.path("\(objects)/Clean.dia")],
        ])
        try tree.write("\(objects)/Warns.dia", "record")
        try tree.write("\(objects)/Clean.dia", "record")
        // Present, and must be ignored: the named records exist, so the build was per-file.
        try tree.write("\(objects)/Fixture.dia", "record")

        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "release")

        #expect(index.units.count == 2)
        #expect(index.units.allSatisfy { $0.source != nil })
    }

    /// The property that must not regress. Absence is reported as absence — the whole point of
    /// reading records at all was that a warm build must never report clean by default.
    @Test("No record of any kind leaves the units per-file, so the run reports them unverified")
    func noRecordAtAllStaysUnverified() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let warns = try tree.write("Sources/Fixture/Warns.swift")
        let objects = Self.nativeReleaseObjects
        try tree.writeMap("\(objects)/output-file-map.json", [
            warns: ["diagnostics": tree.path("\(objects)/Warns.dia")],
        ])

        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "release")

        #expect(index.units.count == 1)
        #expect(index.units.first?.source == warns)
    }

    // MARK: - swiftbuild on Linux

    /// Swift 6.4 builds with `swiftbuild` on Linux, where the configuration directory carries
    /// the platform and architecture: `Release-linux-x86_64`, not `Release`. The map finder
    /// accepted a path component only when it *equalled* the configuration name, so all 98
    /// maps a 6.4 Linux build writes were found by the walk and then discarded by the filter.
    /// `mapCount` reached zero and the checker reported, accurately for what it could see,
    /// "No output file map was found in the build directory" — eleven `WarmBuildTests`
    /// failures on that leg and none on 6.2, which still builds with the native system and
    /// does have a literal `release` component.
    ///
    /// Taken from the job log of run 38188976850, not composed from the documentation.
    @Test("A Linux configuration directory carries platform and arch, and its maps still count")
    func swiftbuildLinuxConfigurationDirectory() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let warns = try tree.write("Sources/Fixture/Warns.swift")
        let objects = Self.swiftbuildLinuxReleaseObjects
        try tree.writeMap("\(objects)/Fixture-OutputFileMap.json", [
            warns: ["diagnostics": tree.path("\(objects)/Warns.dia"), "object": tree.path("\(objects)/Warns.o")],
        ])

        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "release")

        #expect(index.mapCount == 1)
        #expect(index.units.count == 1)
    }

    /// The widened match must not make the configuration meaningless: a debug build's maps are
    /// still not release's, however the platform suffix is spelled.
    @Test("A different configuration's platform-suffixed directory is still excluded")
    func otherConfigurationWithPlatformSuffixIsExcluded() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let warns = try tree.write("Sources/Fixture/Warns.swift")
        let objects = ".build/out/Intermediates.noindex/Fixture.build/Debug-linux-x86_64/Fixture-t.build/Objects-normal/x86_64"
        try tree.writeMap("\(objects)/Fixture-OutputFileMap.json", [
            warns: ["diagnostics": tree.path("\(objects)/Warns.dia")],
        ])

        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "release")

        #expect(index.mapCount == 0)
    }

    // MARK: - 12. swiftbuild layout

    @Test("swiftbuild layout: per-file diagnostics and the \"\"-keyed emit-module record are found")
    func swiftbuildLayout() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let warns = try tree.write("Sources/Fixture/Warns.swift")
        let clean = try tree.write("Sources/Fixture/Clean.swift")
        let objects = Self.swiftbuildObjects
        try tree.writeMap("\(objects)/Fixture-OutputFileMap.json", [
            "": [
                // Named by the map in a per-file build and never written: the index must not
                // take it for a unit.
                "diagnostics": tree.path("\(objects)/Fixture-primary.dia"),
                "emit-module-diagnostics": tree.path("\(objects)/Fixture-primary-emit-module.dia"),
            ],
            warns: ["diagnostics": tree.path("\(objects)/Warns.dia"), "object": tree.path("\(objects)/Warns.o")],
            clean: ["diagnostics": tree.path("\(objects)/Clean.dia"), "object": tree.path("\(objects)/Clean.o")],
        ])

        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "debug")

        #expect(index.mapCount == 1)
        #expect(index.unreadableMaps.isEmpty)
        #expect(index.units == [
            CompileUnit(source: clean, diagnosticsPath: tree.path("\(objects)/Clean.dia")),
            CompileUnit(source: warns, diagnosticsPath: tree.path("\(objects)/Warns.dia")),
            CompileUnit(
                source: nil,
                diagnosticsPath: tree.path("\(objects)/Fixture-primary-emit-module.dia"),
                siblings: [clean, warns]
            ),
        ])
    }

    @Test("Whole-module layout: no per-file records, so the \"\"-keyed diagnostics is the unit")
    func wholeModuleLayout() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let warns = try tree.write("Sources/Fixture/Warns.swift")
        let clean = try tree.write("Sources/Fixture/Clean.swift")
        let objects = Self.swiftbuildReleaseObjects
        try tree.writeMap("\(objects)/Fixture-OutputFileMap.json", [
            "": [
                "diagnostics": tree.path("\(objects)/Fixture-primary.dia"),
                "emit-module-diagnostics": tree.path("\(objects)/Fixture-primary-emit-module.dia"),
            ],
            warns: ["index-unit-output-path": "/Fixture.build/Release/Fixture-t.build/Objects-normal/arm64/Warns.o"],
            clean: ["index-unit-output-path": "/Fixture.build/Release/Fixture-t.build/Objects-normal/arm64/Clean.o"],
        ])

        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "release")

        #expect(index.units == [
            CompileUnit(
                source: nil,
                diagnosticsPath: tree.path("\(objects)/Fixture-primary.dia"),
                siblings: [clean, warns]
            ),
        ])
    }

    // MARK: - 13. native layout

    @Test("native layout: <triple>/debug/<Target>.build/output-file-map.json is found")
    func nativeLayout() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let warns = try tree.write("Sources/Fixture/Warns.swift")
        let objects = Self.nativeObjects
        try tree.writeMap("\(objects)/output-file-map.json", [
            // The native build system's module entry names no diagnostics at all.
            "": ["swift-dependencies": tree.path("\(objects)/primary.swiftdeps")],
            warns: ["diagnostics": tree.path("\(objects)/Warns.dia")],
        ])

        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "debug")

        #expect(index.mapCount == 1)
        #expect(index.units == [
            CompileUnit(source: warns, diagnosticsPath: tree.path("\(objects)/Warns.dia")),
        ])
    }

    // MARK: - 14. configuration

    @Test("A Release map is ignored when the configuration is debug, and the reverse")
    func configurationSelectsTheMap() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let warns = try tree.write("Sources/Fixture/Warns.swift")
        try tree.writeMap("\(Self.swiftbuildObjects)/Fixture-OutputFileMap.json", [
            warns: ["diagnostics": tree.path("\(Self.swiftbuildObjects)/Warns.dia")],
        ])
        try tree.writeMap("\(Self.swiftbuildReleaseObjects)/Fixture-OutputFileMap.json", [
            "": ["diagnostics": tree.path("\(Self.swiftbuildReleaseObjects)/Fixture-primary.dia")],
            warns: [:],
        ])

        let debug = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "debug")
        let release = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "release")

        #expect(debug.mapCount == 1)
        #expect(debug.units.map(\.diagnosticsPath) == [tree.path("\(Self.swiftbuildObjects)/Warns.dia")])
        #expect(release.mapCount == 1)
        #expect(release.units.map(\.diagnosticsPath)
            == [tree.path("\(Self.swiftbuildReleaseObjects)/Fixture-primary.dia")])
    }

    // MARK: - 15. Live and First-party

    @Test("A map entry whose source does not exist yields no unit; nor does one under .build/checkouts")
    func deadAndThirdPartySourcesYieldNoUnit() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let live = try tree.write("Sources/Fixture/Live.swift")
        let deleted = tree.path("Sources/Fixture/Deleted.swift")
        let checkout = try tree.write(".build/checkouts/Dep/Sources/Dep/Dep.swift")
        let objects = Self.swiftbuildObjects
        // The deleted file's record is still on disk, as it is after a real deletion.
        try tree.write("\(objects)/Deleted.dia")
        try tree.writeMap("\(objects)/Fixture-OutputFileMap.json", [
            live: ["diagnostics": tree.path("\(objects)/Live.dia")],
            deleted: ["diagnostics": tree.path("\(objects)/Deleted.dia")],
        ])
        let depObjects = ".build/out/Intermediates.noindex/Dep.build/Debug/Dep-t.build/Objects-normal/arm64"
        try tree.writeMap("\(depObjects)/Dep-OutputFileMap.json", [
            "": ["emit-module-diagnostics": tree.path("\(depObjects)/Dep-primary-emit-module.dia")],
            checkout: ["diagnostics": tree.path("\(depObjects)/Dep.dia")],
        ])

        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "debug")

        #expect(index.mapCount == 2)
        #expect(index.units == [
            CompileUnit(source: live, diagnosticsPath: tree.path("\(objects)/Live.dia")),
        ])
    }

    // MARK: - 16. No map

    @Test("No map anywhere yields an empty index that says it found no map")
    func noMapYieldsEmptyIndex() throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.write("Sources/Fixture/Warns.swift")
        // A record with no map naming it is not evidence of anything.
        try tree.write("\(Self.swiftbuildObjects)/Warns.dia")

        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "debug")

        #expect(index.mapCount == 0)
        #expect(index.units.isEmpty)
    }

    @Test("A map that is not JSON is reported as unreadable, not skipped")
    func unreadableMapIsReported() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let mapPath = try tree.write("\(Self.swiftbuildObjects)/Fixture-OutputFileMap.json", "not json")

        let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "debug")

        #expect(index.mapCount == 1)
        #expect(index.unreadableMaps == [mapPath])
        #expect(index.units.isEmpty)
    }

    // MARK: - 17. Current

    @Test("A record older than its source is not current; one at least as new is")
    func recordOlderThanSourceIsNotCurrent() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let earlier = Date(timeIntervalSince1970: 1_790_000_000)
        let later = Date(timeIntervalSince1970: 1_790_000_060)

        let staleSource = try tree.write("Sources/Fixture/Stale.swift", modified: later)
        let staleRecord = try tree.write("\(Self.swiftbuildObjects)/Stale.dia", modified: earlier)
        let freshSource = try tree.write("Sources/Fixture/Fresh.swift", modified: earlier)
        let freshRecord = try tree.write("\(Self.swiftbuildObjects)/Fresh.dia", modified: later)

        #expect(!CompileUnitIndex.isCurrent(CompileUnit(source: staleSource, diagnosticsPath: staleRecord)))
        #expect(CompileUnitIndex.isCurrent(CompileUnit(source: freshSource, diagnosticsPath: freshRecord)))
        // A missing record is not current either.
        #expect(!CompileUnitIndex.isCurrent(
            CompileUnit(source: freshSource, diagnosticsPath: tree.path("\(Self.swiftbuildObjects)/Missing.dia"))))
    }

    @Test("A module-level record must be no older than every sibling")
    func moduleRecordMustPostdateEverySibling() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let earlier = Date(timeIntervalSince1970: 1_790_000_000)
        let middle = Date(timeIntervalSince1970: 1_790_000_030)
        let later = Date(timeIntervalSince1970: 1_790_000_060)

        let old = try tree.write("Sources/Fixture/Old.swift", modified: earlier)
        let edited = try tree.write("Sources/Fixture/Edited.swift", modified: later)
        let record = try tree.write("\(Self.swiftbuildObjects)/Fixture-primary-emit-module.dia", modified: middle)

        #expect(!CompileUnitIndex.isCurrent(
            CompileUnit(source: nil, diagnosticsPath: record, siblings: [old, edited])))
        #expect(CompileUnitIndex.isCurrent(
            CompileUnit(source: nil, diagnosticsPath: record, siblings: [old])))
    }
}
