import Foundation
import Testing
import QualityGateCore
@testable import BuildChecker

/// Tests of the rules ``RecordedDiagnostics`` applies when reading records, without a build.
///
/// The records are the real Swift 6.4 `.dia` files embedded in
/// `SerializedDiagnosticsReaderTests`; the directory trees and maps are synthetic.
/// See `quality-gate-swift-project/plans/proposals/AWarmBuildForgetsItsWarnings.md` §3.1–3.2.
@Suite("RecordedDiagnostics")
struct RecordedDiagnosticsTests {
    typealias Tree = CompileUnitIndexTests.Tree

    static let objects = CompileUnitIndexTests.swiftbuildObjects
    static let sourceWritten = Date(timeIntervalSince1970: 1_790_000_000)
    static let recordWritten = Date(timeIntervalSince1970: 1_790_000_060)
    static let afterRecord = Date(timeIntervalSince1970: 1_790_000_120)

    /// A tree with one source, a map naming its record, and — when `record` is given — the
    /// record itself, written after the source.
    static func tree(record: [UInt8]?) throws -> Tree {
        let tree = try Tree()
        let source = try tree.write("Sources/Fixture/Warns.swift", modified: sourceWritten)
        let recordPath = tree.path("\(objects)/Warns.dia")
        try tree.writeMap("\(objects)/Fixture-OutputFileMap.json", [
            source: ["diagnostics": recordPath],
        ])
        if let record {
            try Data(record).write(to: URL(fileURLWithPath: recordPath))
            try FileManager.default.setAttributes([.modificationDate: recordWritten], ofItemAtPath: recordPath)
        }
        return tree
    }

    static func collect(_ tree: Tree, buildStarted: Date) -> RecordedDiagnostics {
        RecordedDiagnostics.collect(projectRoot: tree.root.path, buildConfiguration: nil, buildStarted: buildStarted)
    }

    @Test("A record the build left alone is read, and counted as read")
    func upToDateRecordIsRead() throws {
        let tree = try Self.tree(record: try SerializedDiagnosticsReaderTests.bytes(SerializedDiagnosticsReaderTests.warnsBase64))
        defer { tree.remove() }

        // The build started after the record was written: this run did not compile the unit.
        let recorded = Self.collect(tree, buildStarted: Self.afterRecord)

        #expect(recorded.diagnostics.map(\.message) == ["result of call to 'loud()' is unused [#NoUsage]"])
        #expect(recorded.diagnostics.first?.severity == .warning)
        #expect(recorded.coverage == RecordedDiagnostics.Coverage(
            mapCount: 1, unitCount: 1, compiledByThisRun: 0, readFromRecord: 1))
        #expect(recorded.unverifiedDiagnostic == nil)
        #expect(recorded.coverageDiagnostic.severity == .note)
        #expect(recorded.coverageDiagnostic.ruleId == "build.diagnostic-coverage")
        #expect(recorded.coverageDiagnostic.message.contains(
            "1 Swift compile unit(s): 0 compiled by this run, 1 read from recorded diagnostics"))
    }

    @Test("A record written since the build started is counted as compiled by this run")
    func freshRecordIsCountedAsCompiled() throws {
        let tree = try Self.tree(record: try SerializedDiagnosticsReaderTests.bytes(SerializedDiagnosticsReaderTests.warnsBase64))
        defer { tree.remove() }

        let recorded = Self.collect(tree, buildStarted: Self.sourceWritten)

        #expect(recorded.diagnostics.count == 1)
        #expect(recorded.coverage == RecordedDiagnostics.Coverage(
            mapCount: 1, unitCount: 1, compiledByThisRun: 1, readFromRecord: 0))
        #expect(recorded.coverageDiagnostic.message.contains(
            "1 Swift compile unit(s): 1 compiled by this run, 0 read from recorded diagnostics"))
    }

    @Test("No map anywhere is reported as unverified, never as clean")
    func noMapIsUnverified() throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.write("Sources/Fixture/Warns.swift")

        let recorded = Self.collect(tree, buildStarted: Self.afterRecord)

        #expect(recorded.diagnostics.isEmpty)
        #expect(recorded.coverage.mapCount == 0)
        let finding = try #require(recorded.unverifiedDiagnostic)
        #expect(finding.ruleId == "build.warnings-unverified")
        #expect(finding.severity == .warning)
        #expect(finding.message.contains("No output file map was found"))
        #expect(finding.message.contains("rm -rf .build"))
    }

    @Test("A unit whose record is missing is unverified, and named relative to the root")
    func missingRecordIsUnverified() throws {
        let tree = try Self.tree(record: nil)
        defer { tree.remove() }

        let recorded = Self.collect(tree, buildStarted: Self.afterRecord)

        #expect(recorded.diagnostics.isEmpty)
        #expect(recorded.coverage.unverified == ["Sources/Fixture/Warns.swift"])
        let finding = try #require(recorded.unverifiedDiagnostic)
        #expect(finding.ruleId == "build.warnings-unverified")
        #expect(finding.severity == .warning)
        #expect(finding.message.contains("1 of 1 compile units were up to date"))
        #expect(finding.message.contains("(first: `Sources/Fixture/Warns.swift`)"))
        #expect(recorded.coverageDiagnostic.message.contains("1 not verified"))
    }

    @Test("A unit whose record is not a .dia is unverified; reading it does not throw")
    func corruptRecordIsUnverified() throws {
        let tree = try Self.tree(record: [0x9E, 0x37, 0x79, 0xB9, 0x7F, 0x4A, 0x7C, 0x15, 0xF3, 0x9C, 0xC0, 0x60, 0x5C, 0xED, 0xC8, 0x34])
        defer { tree.remove() }

        let recorded = Self.collect(tree, buildStarted: Self.afterRecord)

        #expect(recorded.diagnostics.isEmpty)
        #expect(recorded.coverage.unverified == ["Sources/Fixture/Warns.swift"])
        #expect(recorded.unverifiedDiagnostic?.ruleId == "build.warnings-unverified")
    }

    @Test("A record older than its source is unverified, and its contents are not reported")
    func staleRecordIsUnverified() throws {
        let tree = try Self.tree(record: try SerializedDiagnosticsReaderTests.bytes(SerializedDiagnosticsReaderTests.warnsBase64))
        defer { tree.remove() }
        // The source is edited after the record was written, and nothing recompiled it.
        try FileManager.default.setAttributes(
            [.modificationDate: Self.afterRecord], ofItemAtPath: tree.path("Sources/Fixture/Warns.swift"))

        let recorded = Self.collect(tree, buildStarted: Self.afterRecord)

        #expect(recorded.diagnostics.isEmpty)
        #expect(recorded.coverage.unverified == ["Sources/Fixture/Warns.swift"])
    }

    @Test("The severity of build.warnings-unverified is one constant")
    func unverifiedSeverityIsOneConstant() {
        #expect(RecordedDiagnostics.unverifiedSeverity == .warning)
    }
}
