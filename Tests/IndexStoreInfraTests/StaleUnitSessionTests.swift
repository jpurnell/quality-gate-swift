import Foundation
import Testing
@testable import IndexStoreInfra

/// A session reads only the units its census declared current.
///
/// Exercised against this checkout's own store, with one source file *declared* edited by
/// injecting its date rather than by touching it: the property is what IndexStoreDB returns
/// for units that were not declared, and that does not depend on why they were left out.
/// Building a stale unit for real is `StaleUnitTests`' job, in the checker's suite, where the
/// cost of two builds buys an end-to-end claim.
@Suite("Index session: units not declared current are not read", .serialized)
struct StaleUnitSessionTests {

    private static func localStore() -> URL? {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let store = root.appendingPathComponent(".build/out")
        // SAFETY: read-only existence check inside the test checkout
        guard FileManager.default.fileExists(atPath: StoreLocator.unitsDirectory(in: store).path) else {
            return nil
        }
        return store
    }

    private static var hasLocalStore: Bool { localStore() != nil }

    /// A source this package always compiles, and one beside it to show the rest still answers.
    private static var edited: String {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/IndexStoreInfra/IndexFreshness.swift").path
    }
    private static var untouched: String {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/IndexStoreInfra/StoreLocator.swift").path
    }

    private static func privateDatabase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-indexdb-staleunit-\(UUID().uuidString)")
    }

    /// The census with `edited` declared modified a moment from now, so every unit for it is
    /// older than its source.
    private static func censusDeclaringEdit(store: URL, lib: URL) async -> IndexUnitCensus? {
        let target = URL(fileURLWithPath: edited).resolvingSymlinksInPath().path
        return await IndexStoreSession.takeCensus(storePath: store, libPath: lib) { path in
            if URL(fileURLWithPath: path).resolvingSymlinksInPath().path == target {
                return Date.distantFuture
            }
            return IndexStoreSession.modificationDate(ofSource: path)
        }
    }

    @Test("a census of this store reads its units and finds the sources they describe",
          .enabled(if: hasLocalStore, "no swiftbuild index store in this checkout"))
    func censusReadsRealUnits() async throws {
        let store = try #require(Self.localStore())
        let lib = try #require(IndexStoreSession.findLibIndexStore())

        let census = try #require(await IndexStoreSession.takeCensus(storePath: store, libPath: lib))

        #expect(census.examined > 100, "expected this package's own sources among the units; examined \(census.examined)")
        #expect(census.currentOutputPaths.count + census.ignored == census.examined)
    }

    @Test("a source edited after its units were written is counted stale and left undescribed",
          .enabled(if: hasLocalStore, "no swiftbuild index store in this checkout"))
    func editedSourceIsStaleInTheCensus() async throws {
        let store = try #require(Self.localStore())
        let lib = try #require(IndexStoreSession.findLibIndexStore())

        let honest = try #require(await IndexStoreSession.takeCensus(storePath: store, libPath: lib))
        let declared = try #require(await Self.censusDeclaringEdit(store: store, lib: lib))

        #expect(declared.stale > honest.stale, "declaring a source edited made none of its units stale")
        let resolved = declared.sourcesWithoutCurrentUnit.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        #expect(resolved.contains(URL(fileURLWithPath: Self.edited).resolvingSymlinksInPath().path))
    }

    /// Both layers at once. The first session ingests every unit into a database, as every run
    /// before this change did. The second opens **that database** with one file's units left
    /// out of the census — and must answer nothing for the file, although the database still
    /// holds what the first session ingested from them.
    @Test("a unit ingested by an earlier session is not read once it stops being current",
          .enabled(if: hasLocalStore, "no swiftbuild index store in this checkout"))
    func databaseDoesNotAnswerForUnitsNoLongerCurrent() async throws {
        let store = try #require(Self.localStore())
        let lib = try #require(IndexStoreSession.findLibIndexStore())
        let database = Self.privateDatabase()
        defer {
            // silent: best-effort cleanup of a test-private database directory
            try? FileManager.default.removeItem(at: database)
        }

        let symbolsWhenEverythingIsRead: Int
        do {
            // No census: every unit in the store is ingested, the behaviour being replaced.
            let everything = try IndexStoreSession(
                storePath: store, libPath: lib, databaseDirectory: database, census: nil)
            symbolsWhenEverythingIsRead = everything.db.symbols(inFilePath: Self.edited).count
            #expect(everything.unitCensus == nil)
        }
        #expect(symbolsWhenEverythingIsRead > 0, "the fixture file is not in this store; the test would prove nothing")

        let declared = try #require(await Self.censusDeclaringEdit(store: store, lib: lib))
        let session = try IndexStoreSession(
            storePath: store, libPath: lib, databaseDirectory: database, census: declared)

        #expect(session.db.symbols(inFilePath: Self.edited).isEmpty,
                "the database answered for a file whose every unit predates its source")
        #expect(session.db.symbolOccurrences(inFilePath: Self.edited).isEmpty,
                "occurrences were returned from units that were not declared current")
        #expect(!session.db.symbols(inFilePath: Self.untouched).isEmpty,
                "leaving one file's units out silenced a file whose units are current")
    }

    /// The other direction, and the one that keeps the fix from costing findings: units that
    /// *are* current must answer exactly as they did when every unit was read.
    @Test("current units answer the same whether or not others were left out",
          .enabled(if: hasLocalStore, "no swiftbuild index store in this checkout"))
    func currentUnitsAnswerUnchanged() async throws {
        let store = try #require(Self.localStore())
        let lib = try #require(IndexStoreSession.findLibIndexStore())
        let database = Self.privateDatabase()
        defer {
            // silent: best-effort cleanup of a test-private database directory
            try? FileManager.default.removeItem(at: database)
        }

        let namesWhenEverythingIsRead: [String]
        do {
            let everything = try IndexStoreSession(
                storePath: store, libPath: lib, databaseDirectory: database, census: nil)
            namesWhenEverythingIsRead = Set(everything.db.symbols(inFilePath: Self.untouched).map(\.usr)).sorted()
        }

        let declared = try #require(await Self.censusDeclaringEdit(store: store, lib: lib))
        let session = try IndexStoreSession(
            storePath: store, libPath: lib, databaseDirectory: database, census: declared)
        let names = Set(session.db.symbols(inFilePath: Self.untouched).map(\.usr)).sorted()

        #expect(names == namesWhenEverythingIsRead)
    }
}
