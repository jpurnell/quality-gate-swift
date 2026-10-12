import Foundation
import Testing
import QualityGateCore
@testable import BuildChecker

/// A recorded diagnostic is evidence about the file it points at *as that file was when the
/// record was written* — and a record is not always the file's own.
///
/// The compiler writes a diagnostic about `F.swift` into other units' records too: every primary
/// file of a batch that contains a macro expansion gets the batch's diagnostics, so a warning in
/// `Suite30Tests.swift` is also in `Suite25Tests.dia` … `Suite29Tests.dia`. When `Suite30Tests`
/// is fixed, only its own unit is recompiled; the five sibling records keep the warning, at a
/// line that no longer holds the code. Reproduced with a real `swift build` (60 Swift Testing
/// files, Swift 6.4) and observed in swift-oauth, SwiftMCPClient and ClassGraph.
///
/// The trees here are synthetic and the records' contents are supplied through the reader seam
/// of `RecordedDiagnostics.collect`, because the question is which records to believe, not how
/// to decode one. See `quality-gate-swift-project/plans/proposals/AWarmBuildForgetsItsWarnings.md`,
/// "Found after shipping (2026-10-06)".
@Suite("RecordedDiagnostics: a record older than the file it describes")
struct StaleRecordedDiagnosticsTests {
    typealias Tree = CompileUnitIndexTests.Tree

    static let objects = CompileUnitIndexTests.swiftbuildObjects

    /// Moments, a minute apart: sources written, first build, an edit, the rebuild, this run.
    static let written = Date(timeIntervalSince1970: 1_790_000_000)
    static let firstBuild = Date(timeIntervalSince1970: 1_790_000_060)
    static let edited = Date(timeIntervalSince1970: 1_790_000_120)
    static let rebuilt = Date(timeIntervalSince1970: 1_790_000_180)
    static let thisRun = Date(timeIntervalSince1970: 1_790_000_240)

    /// A package of per-file units whose records hold what the test says they hold.
    struct Package {
        let tree: Tree
        var contents: [String: [Diagnostic]] = [:]
        var entries: [String: [String: String]] = [:]

        init() throws {
            tree = try Tree()
        }

        /// The absolute path of a source file in the fixture target.
        func source(_ name: String) -> String {
            tree.path("Sources/Fixture/\(name)")
        }

        /// Adds a source, last modified at `modified`, whose unit's record was written at
        /// `recorded` and holds `diagnostics`.
        mutating func addUnit(
            _ name: String,
            modified: Date,
            recorded: Date,
            holding diagnostics: [Diagnostic] = []
        ) throws {
            let path = try tree.write("Sources/Fixture/\(name)", modified: modified)
            let record = tree.path("\(StaleRecordedDiagnosticsTests.objects)/\((name as NSString).deletingPathExtension).dia")
            try tree.write(
                "\(StaleRecordedDiagnosticsTests.objects)/\((name as NSString).deletingPathExtension).dia",
                modified: recorded)
            entries[path] = ["diagnostics": record]
            contents[record] = diagnostics
        }

        /// Writes the output file map and reads the records.
        func collect() throws -> RecordedDiagnostics {
            try tree.writeMap("\(StaleRecordedDiagnosticsTests.objects)/Fixture-OutputFileMap.json", entries)
            let index = CompileUnitIndex.scan(buildDirectory: tree.buildDirectory.path, configuration: "debug")
            let contents = contents
            return RecordedDiagnostics.collect(
                index: index,
                projectRoot: tree.root.path,
                buildStarted: StaleRecordedDiagnosticsTests.thisRun,
                read: { contents[$0] ?? [] }
            )
        }
    }

    static func warning(_ message: String, in path: String, line: Int, column: Int = 9) -> Diagnostic {
        Diagnostic(
            severity: .warning, message: message, filePath: path,
            lineNumber: line, columnNumber: column, ruleId: "swift-compiler")
    }

    static func note(_ message: String, in path: String, line: Int, column: Int = 9) -> Diagnostic {
        Diagnostic(
            severity: .note, message: message, filePath: path,
            lineNumber: line, columnNumber: column, ruleId: "swift-compiler")
    }

    static func locations(_ recorded: RecordedDiagnostics) -> [String] {
        recorded.diagnostics.map {
            "\(($0.filePath.map { ($0 as NSString).lastPathComponent }) ?? "-"):\($0.lineNumber ?? 0) \($0.severity.rawValue)"
        }
    }

    // MARK: - The defect

    @Test("A warning held only in a sibling's record, older than the file it points at, is not reported")
    func siblingRecordOlderThanTheEditedFileIsNotReported() throws {
        var package = try Package()
        defer { package.tree.remove() }
        // F was fixed and recompiled: its own record is new and clean.
        try package.addUnit("F.swift", modified: Self.edited, recorded: Self.rebuilt)
        // G was not recompiled. Its record still says what F looked like at the first build.
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Self.warning("result of call to 'loud()' is unused [#NoUsage]", in: package.source("F.swift"), line: 6),
        ])

        let recorded = try package.collect()

        #expect(Self.locations(recorded) == [])
        #expect(recorded.unverifiedDiagnostic == nil, "both units have a current, readable record")
        #expect(recorded.coverageDiagnostic.message.contains(
            "2 Swift compile unit(s): 0 compiled by this run, 2 read from recorded diagnostics"))
        #expect(recorded.coverageDiagnostic.message.contains("1 recorded diagnostic(s) discarded as stale"))
    }

    @Test("The same warning in the file's own fresh record is reported once, where it is now")
    func ownFreshRecordIsReportedOnce() throws {
        var package = try Package()
        defer { package.tree.remove() }
        let file = package.source("F.swift")
        // F was edited — a line added above the warning — and recompiled; the warning is still
        // there, one line down.
        try package.addUnit("F.swift", modified: Self.edited, recorded: Self.rebuilt, holding: [
            Self.warning("result of call to 'loud()' is unused [#NoUsage]", in: file, line: 7),
        ])
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Self.warning("result of call to 'loud()' is unused [#NoUsage]", in: file, line: 6),
        ])

        let recorded = try package.collect()

        #expect(Self.locations(recorded) == ["F.swift:7 warning"])
        #expect(recorded.coverageDiagnostic.message.contains("1 recorded diagnostic(s) discarded as stale"))
    }

    @Test("A stale warning takes its notes with it, wherever they point")
    func staleWarningTakesItsNotes() throws {
        var package = try Package()
        defer { package.tree.remove() }
        try package.addUnit("F.swift", modified: Self.edited, recorded: Self.rebuilt)
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Self.warning("attempting to access 'placeholder' within its own getter", in: package.source("F.swift"), line: 18),
            Self.note("access 'self' explicitly to silence this warning", in: package.source("G.swift"), line: 3),
            Self.warning("variable 'kept' was never used", in: package.source("G.swift"), line: 4),
        ])

        let recorded = try package.collect()

        #expect(Self.locations(recorded) == ["G.swift:4 warning"])
    }

    @Test("A warning inside a macro expansion is judged by the file the expansion is in")
    func macroExpansionIsJudgedByItsExpansionSite() throws {
        var package = try Package()
        defer { package.tree.remove() }
        // The compiler locates the warning in a generated buffer that is never on disk, and
        // attaches a note naming the real file.
        let buffer = "/var/folders/zz/T/swift-generated-sources/@__swiftmacro_5Tests0006Fswift_6expectfMf_.swift"
        try package.addUnit("F.swift", modified: Self.edited, recorded: Self.rebuilt)
        try package.addUnit("H.swift", modified: Self.written, recorded: Self.firstBuild)
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Self.warning("no 'async' operations occur within 'await' expression", in: buffer, line: 1, column: 22),
            Self.note("in expansion of macro 'expect' here", in: package.source("F.swift"), line: 5, column: 5),
            Self.warning("no 'async' operations occur within 'await' expression", in: buffer, line: 1, column: 30),
            Self.note("in expansion of macro 'expect' here", in: package.source("H.swift"), line: 9, column: 5),
        ])

        let recorded = try package.collect()

        // F changed after G's record was written; H did not.
        #expect(recorded.diagnostics.map(\.columnNumber) == [30, 5])
        #expect(Self.locations(recorded).last == "H.swift:9 note")
    }

    @Test("A macro expansion buffer that is still on disk does not vouch for its warning")
    func expansionBufferOnDiskDoesNotVouchForItsWarning() throws {
        var package = try Package()
        defer { package.tree.remove() }
        // The compiler does write the buffer out, under the temporary directory, when it has a
        // diagnostic to locate in it — and does not touch it again when the expansion site is
        // fixed. Its own date says nothing; the site's does. Observed with a real build: this
        // was the one warning of four that survived the first version of the rule.
        let buffer = try package.tree.write(
            "tmp/swift-generated-sources/@__swiftmacro_5Tests0006Fswift_6expectfMf_.swift", modified: Self.written)
        let other = try package.tree.write(
            "tmp/swift-generated-sources/@__swiftmacro_5Tests0006Hswift_6expectfMf_.swift", modified: Self.written)
        try package.addUnit("F.swift", modified: Self.edited, recorded: Self.rebuilt)
        try package.addUnit("H.swift", modified: Self.written, recorded: Self.firstBuild)
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Self.warning("no 'async' operations occur within 'await' expression", in: buffer, line: 1, column: 22),
            Self.note("in expansion of macro 'expect' here", in: package.source("F.swift"), line: 12, column: 9),
            Self.warning("no 'async' operations occur within 'await' expression", in: other, line: 1, column: 30),
            Self.note("in expansion of macro 'expect' here", in: package.source("H.swift"), line: 9, column: 5),
        ])

        let recorded = try package.collect()

        #expect(recorded.diagnostics.map(\.columnNumber) == [30, 5])
        #expect(recorded.coverageDiagnostic.message.contains("1 recorded diagnostic(s) discarded as stale"))
    }

    @Test("A diagnostic that points only at files not on disk is kept: there is nothing to compare its record with")
    func diagnosticPointingAtNothingOnDiskIsKept() throws {
        var package = try Package()
        defer { package.tree.remove() }
        // Not how a deleted file arrives — deleting a source recompiles its whole target — but
        // how a record written under another spelling of the package's path does.
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Self.warning("variable 'gone' was never used", in: package.source("NotOnDisk.swift"), line: 2),
        ])

        let recorded = try package.collect()

        #expect(Self.locations(recorded) == ["NotOnDisk.swift:2 warning"])
        #expect(!recorded.coverageDiagnostic.message.contains("stale"))
    }

    @Test("A header has no unit of its own: its diagnostics follow the same rule")
    func headerWithoutAUnitFollowsTheSameRule() throws {
        var package = try Package()
        defer { package.tree.remove() }
        let unchanged = try package.tree.write("Sources/Fixture/include/Unchanged.h", modified: Self.written)
        let changed = try package.tree.write("Sources/Fixture/include/Changed.h", modified: Self.edited)
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Self.warning("'old()' is deprecated", in: unchanged, line: 3),
            Self.warning("'older()' is deprecated", in: changed, line: 4),
        ])

        let recorded = try package.collect()

        #expect(Self.locations(recorded) == ["Unchanged.h:3 warning"])
    }

    @Test("The same stale warning in several sibling records is counted once")
    func staleCountIsOfDistinctDiagnostics() throws {
        var package = try Package()
        defer { package.tree.remove() }
        let stale = [
            Self.warning("result of call to 'loud()' is unused [#NoUsage]", in: package.source("F.swift"), line: 6),
            Self.warning("variable 'never' was never used", in: package.source("F.swift"), line: 8),
        ]
        try package.addUnit("F.swift", modified: Self.edited, recorded: Self.rebuilt)
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: stale)
        try package.addUnit("H.swift", modified: Self.written, recorded: Self.firstBuild, holding: stale)
        try package.addUnit("I.swift", modified: Self.written, recorded: Self.firstBuild, holding: stale)

        let recorded = try package.collect()

        #expect(Self.locations(recorded) == [])
        #expect(recorded.coverageDiagnostic.message.contains(
            "4 Swift compile unit(s): 0 compiled by this run, 4 read from recorded diagnostics"))
        #expect(recorded.coverageDiagnostic.message.contains("2 recorded diagnostic(s) discarded as stale"))
    }

    // MARK: - What must keep being reported

    @Test("A cross-unit warning about an unchanged file is still reported after an edit elsewhere")
    func crossUnitWarningAboutAnUnchangedFileIsStillReported() throws {
        var package = try Package()
        defer { package.tree.remove() }
        try package.addUnit("F.swift", modified: Self.written, recorded: Self.firstBuild)
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Self.warning("instance method 'fooo()' nearly matches defaulted requirement 'foo()'", in: package.source("F.swift"), line: 4),
        ])
        // The unrelated edit: H changed and was recompiled.
        try package.addUnit("H.swift", modified: Self.edited, recorded: Self.rebuilt)

        let recorded = try package.collect()

        #expect(Self.locations(recorded) == ["F.swift:4 warning"])
        #expect(!recorded.coverageDiagnostic.message.contains("stale"))
    }

    @Test("Recompiling a file without editing it does not discard what a sibling recorded about it")
    func recompiledButUnchangedFileKeepsACrossUnitWarning() throws {
        var package = try Package()
        defer { package.tree.remove() }
        // F's own record is newer than G's — F was recompiled because something it depends on
        // changed — but F itself is as it was when G's record was written, and F's own record
        // does not hold a warning that only compiling G produces.
        try package.addUnit("F.swift", modified: Self.written, recorded: Self.rebuilt)
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Self.warning("instance method 'fooo()' nearly matches defaulted requirement 'foo()'", in: package.source("F.swift"), line: 4),
        ])

        let recorded = try package.collect()

        #expect(Self.locations(recorded) == ["F.swift:4 warning"])
    }

    @Test("A warning in an unchanged file keeps its notes, even one pointing into a file edited since")
    func currentWarningKeepsItsNotes() throws {
        var package = try Package()
        defer { package.tree.remove() }
        try package.addUnit("F.swift", modified: Self.edited, recorded: Self.rebuilt)
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Self.warning("conformance of 'Thing' to protocol 'Describable' crosses into main actor-isolated code", in: package.source("G.swift"), line: 6),
            Self.note("main actor-isolated instance method 'describe()' cannot satisfy nonisolated requirement", in: package.source("F.swift"), line: 3),
        ])

        let recorded = try package.collect()

        #expect(Self.locations(recorded) == ["G.swift:6 warning", "F.swift:3 note"])
        #expect(!recorded.coverageDiagnostic.message.contains("stale"))
    }

    @Test("A diagnostic with no location is kept: there is no file for it to be stale against")
    func diagnosticWithoutALocationIsKept() throws {
        var package = try Package()
        defer { package.tree.remove() }
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Diagnostic(severity: .warning, message: "module-level remark", ruleId: "swift-compiler"),
        ])

        let recorded = try package.collect()

        #expect(recorded.diagnostics.map(\.message) == ["module-level remark"])
    }

    // MARK: - End to end

    @Test("createResult: a stale sibling record alone leaves the build passed, and the note says what was discarded")
    func staleRecordAloneLeavesTheBuildPassed() throws {
        var package = try Package()
        defer { package.tree.remove() }
        try package.addUnit("F.swift", modified: Self.edited, recorded: Self.rebuilt)
        try package.addUnit("G.swift", modified: Self.written, recorded: Self.firstBuild, holding: [
            Self.warning("result of call to 'loud()' is unused [#NoUsage]", in: package.source("F.swift"), line: 6),
        ])

        let result = BuildChecker.createResult(
            output: "Build complete!", exitCode: 0, duration: .seconds(1), recorded: try package.collect())

        #expect(result.status == .passed)
        #expect(result.compilerWarnings.isEmpty)
        #expect(result.finding("build.warnings-unverified") == nil)
        #expect(result.finding("build.diagnostic-coverage")?.message.contains(
            "1 recorded diagnostic(s) discarded as stale") == true)
    }
}
