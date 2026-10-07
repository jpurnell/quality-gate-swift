import Foundation
import IndexStoreInfra
import QualityGateCore
import Testing
@testable import UnreachableCodeAuditor

/// A stale index unit beside a fresh one for the same source file.
///
/// An index store is not replaced by a build; it is added to. swiftbuild compiles an
/// executable target's sources twice when a test target imports it — once for the product and
/// once for a `…-testable` variant — and each compilation writes its own unit, named after its
/// own output path. When the test target stops importing the executable, the testable variant
/// is never built again and its units are never removed. They describe the source as it was on
/// the day of that last build.
///
/// The store's freshness was judged by comparing its *newest* unit with the newest source, which
/// says nothing about any particular unit. In Ignite a unit dated 27 August sat beside one
/// written that day, the note read "1m newer than the newest source", and the checker reported a
/// deleted enum case as unreachable at `QRCodeError.swift:11:10` — a line that by then held a
/// different declaration.
///
/// This suite builds that situation the way it arises rather than faking a unit file, because
/// the property under test is what IndexStoreDB returns for a real store, and a fixture that
/// imitates the store imitates the assumption too.
@Suite("Unreachable: stale index units beside fresh ones", .serialized)
struct StaleUnitTests {

    private static let ruleId = "unreachable.cross_module.unreachable_from_entry"

    /// The error enums of the fixture. Several rather than one, because which of a file's two
    /// units IndexStoreDB reads first is decided by the hash of the unit's name: a single file
    /// reproduces the defect only when that order happens to favour the stale unit.
    private static let enumNames = [
        "QRCodeError", "NetworkError", "ParseError", "StorageError", "RenderError", "ReproError",
    ]

    /// One error enum whose third case nothing references.
    private static func errorEnum(_ name: String, includingDeadCase: Bool) -> String {
        var lines = [
            "/// Errors of one kind.",
            "enum \(name): Error {",
            "    case first\(name)",
            "    case second\(name)",
        ]
        if includingDeadCase { lines.append("    case obsolete\(name)") }
        lines.append("    case last\(name)")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func validator() -> String {
        var lines = [
            "/// Validates input for the fixture tool.",
            "struct Validator {",
            "    /// Validates `input`.",
            "    func validate(_ input: String) throws {",
        ]
        for name in enumNames {
            for prefix in ["first", "second", "last"] {
                lines.append("        if input == \"\(prefix)\(name)\" { throw \(name).\(prefix)\(name) }")
            }
        }
        lines += [
            "    }",
            "",
            "    /// Unreachable in every version of the fixture: the finding that must survive.",
            "    func neverCalled() -> Int { 42 }",
            "}",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func manifest(testsImportExecutable: Bool) -> String {
        let dependencies = testsImportExecutable ? "[\"FixtureCLI\"]" : "[]"
        return """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "StaleUnitFixture",
                targets: [
                    .executableTarget(name: "FixtureCLI"),
                    .testTarget(name: "FixtureTests", dependencies: \(dependencies)),
                ]
            )

            """
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes the fixture as it stood before the edit: every enum has a dead case, and the test
    /// target imports the executable, so its sources are compiled twice.
    private static func writeBefore(at root: URL) throws {
        let sources = root.appendingPathComponent("Sources/FixtureCLI")
        try write(manifest(testsImportExecutable: true), to: root.appendingPathComponent("Package.swift"))
        for name in enumNames {
            try write(errorEnum(name, includingDeadCase: true), to: sources.appendingPathComponent("\(name).swift"))
        }
        try write(validator(), to: sources.appendingPathComponent("Validator.swift"))
        try write(
            """
            do {
                try Validator().validate(CommandLine.arguments.last ?? "")
            } catch {
                print("invalid")
            }

            """,
            to: sources.appendingPathComponent("main.swift"))
        try write(
            """
            import Testing
            @testable import FixtureCLI

            @Test func validates() throws {
                try Validator().validate("ok")
            }

            """,
            to: root.appendingPathComponent("Tests/FixtureTests/FixtureTests.swift"))
    }

    /// Applies the edit: the dead cases are deleted, as the checker asked, and the test target
    /// stops importing the executable — so the testable variant's units are orphaned in place.
    private static func writeAfter(at root: URL) throws {
        let sources = root.appendingPathComponent("Sources/FixtureCLI")
        try write(manifest(testsImportExecutable: false), to: root.appendingPathComponent("Package.swift"))
        for name in enumNames {
            try write(errorEnum(name, includingDeadCase: false), to: sources.appendingPathComponent("\(name).swift"))
        }
        try write(
            """
            import Testing

            @Test func arithmetic() {
                #expect(1 + 1 == 2)
            }

            """,
            to: root.appendingPathComponent("Tests/FixtureTests/FixtureTests.swift"))
    }

    private func flaggedNames(_ result: CheckResult) -> [String] {
        result.diagnostics
            .filter { $0.ruleId == Self.ruleId }
            .map(\.message)
            .sorted()
    }

    /// Builds the fixture, edits it, and audits it again.
    ///
    /// One test rather than three, because each audit costs a build and the three properties
    /// are claims about the same run: what is no longer reported, what still is, and what the
    /// run says about the units it declined to read.
    @Test("a deleted symbol is not reported from a superseded unit, and a live finding survives")
    func deletedSymbolIsNotReportedFromAStaleUnit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-stale-unit-\(UUID().uuidString)", isDirectory: true)
        defer {
            // silent: best-effort cleanup of a test-private fixture package
            try? FileManager.default.removeItem(at: root)
        }
        let auditor = UnreachableCodeAuditor()

        try Self.writeBefore(at: root)
        let before = try await auditor.auditPackage(at: root, configuration: Configuration())
        let flaggedBefore = flaggedNames(before)
        // The fixture is sound only if the first audit sees what the edit then removes. Without
        // this the second half could pass against a package that never indexed.
        #expect(flaggedBefore.count == Self.enumNames.count + 1,
                "expected one dead case per enum plus neverCalled(); got \(flaggedBefore)")

        // The session is cached per store path for the life of the process, which in the CLI is
        // one run. Two audits in one process must release it, or the second reads the first's.
        await SharedIndexStore.drain()
        try Self.writeAfter(at: root)
        let after = try await auditor.auditPackage(at: root, configuration: Configuration())
        let flaggedAfter = flaggedNames(after)

        let ghosts = flaggedAfter.filter { $0.contains("obsolete") }
        #expect(ghosts.isEmpty,
                "symbols deleted from the source were reported from units that predate the edit: \(ghosts)")

        #expect(flaggedAfter.count == 1, "expected only neverCalled(); got \(flaggedAfter)")
        #expect(flaggedAfter.first?.contains("neverCalled()") == true,
                "a symbol that is unreachable in the current source must still be reported")

        let note = after.diagnostics.first { $0.ruleId == "unreachable.index.age" }?.message ?? ""
        // Whatever the build system left behind, the note must account for the units it read
        // and the units it did not.
        #expect(note.contains("ignored"), "the freshness note must count the units it did not read: \(note)")
        #if os(macOS)
        // The exact counts are a fact about swiftbuild, which compiles an executable a second
        // time for the test target that imports it. Eight sources were compiled for that
        // testable variant before the edit. Six were then rewritten (stale); `Validator.swift`
        // and `main.swift` were not, so their testable units are merely older than the
        // product's (superseded). The native build system on Linux writes one unit per source,
        // leaves nothing behind for this edit to strand, and reports 0 ignored — which is the
        // right answer there, and is why the properties above are the portable ones.
        #expect(note.contains("8 ignored"), "\(note)")
        #expect(note.contains("6 stale"), "\(note)")
        #expect(note.contains("2 superseded"), "\(note)")
        #endif
        await SharedIndexStore.drain()
    }
}

/// The accounting for findings that were withheld because the source disagreed with the index.
@Suite("Unreachable: source-mismatch note")
struct SourceMismatchNoteTests {

    @Test("no mismatches, no note")
    func silentWhenNothingWasWithheld() {
        #expect(IndexStorePass.sourceMismatchNote([]) == nil)
    }

    @Test("a withheld finding is counted and named")
    func countsAndNames() throws {
        let note = try #require(IndexStorePass.sourceMismatchNote([
            (name: "obsoleteQRCodeError", file: "/pkg/Sources/CLI/QRCodeError.swift", line: 11),
        ]))
        #expect(note.severity == .note)
        #expect(note.ruleId == "unreachable.index.source-mismatch")
        #expect(note.message.hasPrefix("1 unreferenced definition the index reports is not written"))
        #expect(note.message.contains("'obsoleteQRCodeError' at QRCodeError.swift:11"))
    }

    @Test("more than three are counted in full and named in part")
    func truncatesTheList() throws {
        let mismatches = (1...5).map { (name: "ghost\($0)", file: "/pkg/A.swift", line: $0) }
        let note = try #require(IndexStorePass.sourceMismatchNote(mismatches))
        #expect(note.message.hasPrefix("5 unreferenced definitions the index reports are not written"))
        #expect(note.message.contains("'ghost1' at A.swift:1, 'ghost2' at A.swift:2, 'ghost3' at A.swift:3, and 2 more."))
        #expect(note.message.contains("ghost4") == false)
    }
}

/// What the checker says, and whether it reads the index, once the units have been examined
/// one by one.
@Suite("Unreachable: unit provenance")
struct UnitProvenanceTests {

    private let store = URL(fileURLWithPath: "/pkg/.build/out")

    private var located: StoreLocator.LocatedStore {
        StoreLocator.LocatedStore(url: store, measurement: .measured(IndexFreshness(
            newestSource: Date(timeIntervalSince1970: 1_759_600_000),
            newestIndexUnit: Date(timeIntervalSince1970: 1_759_700_000),
            unitCount: 67)))
    }

    private func census(undescribed: [String]) -> IndexUnitCensus {
        IndexUnitCensus(
            currentOutputPaths: ["/b/a.o", "/b/b.o"], examined: 5, stale: 2, superseded: 1,
            orphaned: 0, sourcesWithoutCurrentUnit: undescribed)
    }

    @Test("ignored units beside current ones are counted in the note and the pass runs")
    func ignoredUnitsAreCounted() {
        let outcome = UnreachableCodeAuditor.unitProvenance(
            located: located, census: census(undescribed: []), projectSources: ["/pkg/Sources/A.swift"])

        #expect(outcome.shouldRun)
        #expect(outcome.diagnostics.count == 1)
        #expect(outcome.diagnostics.first?.ruleId == "unreachable.index.age")
        #expect(outcome.diagnostics.first?.message.contains("3 ignored (2 stale, 1 superseded, 0 orphaned)") == true)
    }

    /// Setting a stale unit aside removes its references along with its definitions. When it
    /// was the only unit a project file had, everything that file alone calls would now be
    /// reported as unreachable — so the pass must not run, exactly as for a stale store.
    @Test("a project source with no current unit replaces the findings with a barrier")
    func undescribedProjectSourceIsABarrier() {
        let outcome = UnreachableCodeAuditor.unitProvenance(
            located: located,
            census: census(undescribed: ["/pkg/Tests/ATests.swift"]),
            projectSources: ["/pkg/Sources/A.swift", "/pkg/Tests/ATests.swift"])

        #expect(outcome.shouldRun == false)
        #expect(outcome.diagnostics.count == 1)
        #expect(outcome.diagnostics.first?.severity == .error)
        #expect(outcome.diagnostics.first?.ruleId == "unreachable.index.stale-barrier")
        #expect(outcome.diagnostics.first?.message.contains("ATests.swift") == true)
    }

    /// The census covers every unit in the store: dependencies' sources, and files this
    /// project's configuration excludes. A hole in something the checker never reads is not a
    /// reason to refuse to read what it does.
    @Test("an undescribed source outside the project's own files does not raise the barrier")
    func undescribedForeignSourceIsNotABarrier() {
        let outcome = UnreachableCodeAuditor.unitProvenance(
            located: located,
            census: census(undescribed: ["/pkg/.build/checkouts/dep/Sources/Dep/D.swift"]),
            projectSources: ["/pkg/Sources/A.swift"])

        #expect(outcome.shouldRun)
        #expect(outcome.diagnostics.first?.ruleId == "unreachable.index.age")
    }

    @Test("a store whose units could not be examined is read, and the note says how")
    func unexaminedStoreIsReadAndSaysSo() {
        let outcome = UnreachableCodeAuditor.unitProvenance(
            located: located, census: nil, projectSources: ["/pkg/Sources/A.swift"])

        #expect(outcome.shouldRun)
        #expect(outcome.diagnostics.first?.message.contains("not examined individually") == true)
    }
}
