import Foundation
import Testing
@testable import IndexStoreInfra

/// The IndexStoreDB database must outlive the run that built it.
///
/// `IngestionIsNotAnalysis.md`: a profile of `--check recursion --no-cache` put the
/// entire 11s working set inside `IndexStoreDB.init` ingesting 3,402 unit records into
/// a throwaway temp-directory LMDB. Persisting the database next to the store lets
/// `pollForUnitChangesAndWait()` process only changed units on subsequent runs.
@Suite("Persistent index database")
struct PersistentIndexDatabaseTests {

    // MARK: - Pure derivation

    @Test("database directory is derived beside the swiftbuild store")
    func derivesBesideSwiftbuildStore() {
        let store = URL(fileURLWithPath: "/repo/.build/out")
        let db = IndexStoreSession.databaseDirectory(for: store)
        #expect(db.path == "/repo/.build/quality-gate-indexdb-out")
    }

    @Test("database directory is derived beside the managed store")
    func derivesBesideManagedStore() {
        let store = URL(fileURLWithPath: "/repo/.build/index-build/index-store")
        let db = IndexStoreSession.databaseDirectory(for: store)
        #expect(db.path == "/repo/.build/index-build/quality-gate-indexdb-index-store")
    }

    @Test("database directory is derived beside an Xcode DerivedData store")
    func derivesBesideDerivedDataStore() {
        let store = URL(fileURLWithPath: "/dd/Proj-abc/Index.noindex/DataStore")
        let db = IndexStoreSession.databaseDirectory(for: store)
        #expect(db.path == "/dd/Proj-abc/Index.noindex/quality-gate-indexdb-DataStore")
    }

    // MARK: - Lifecycle (skipped when this checkout has no store, like the probe suite)

    /// This repository's own swiftbuild store, or nil on a clean checkout.
    ///
    /// Static so the `.enabled(if:)` traits below can consult it before a test runs.
    private static func localStore() -> URL? {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let store = root.appendingPathComponent(".build/out")
        let units = store.appendingPathComponent("v5/units")
        // SAFETY: read-only existence check inside the test checkout
        guard FileManager.default.fileExists(atPath: units.path) else { return nil }
        return store
    }

    /// Whether this checkout has an index store for these tests to read.
    ///
    /// These three tests used to open with `guard let store = localStore() else { return }`,
    /// which reported success on a clean checkout having asserted nothing — the shape
    /// `unasserted-optional-unwrap` was written to find, in the repository that ships it.
    /// The condition was real; the way it was spelled turned "this machine cannot run the
    /// test" into "the test passed". As a trait, the framework records a skip instead.
    private static var hasLocalStore: Bool { localStore() != nil }

    @Test("the database survives the session that built it, and a second session reuses it",
          .enabled(if: hasLocalStore, "no swiftbuild index store in this checkout"))
    func databasePersistsAcrossSessions() throws {
        let store = try #require(Self.localStore())
        guard let lib = IndexStoreSession.findLibIndexStore() else {
            Issue.record("libIndexStore.dylib not found via active toolchain")
            return
        }
        let dbDir = IndexStoreSession.databaseDirectory(for: store)

        try autoreleasepool {
            let first = try IndexStoreSession(storePath: store, libPath: lib)
            _ = first.db.symbols(inFilePath: "/nonexistent.swift")
        }
        // SAFETY: read-only existence check inside the test checkout
        #expect(FileManager.default.fileExists(atPath: dbDir.path),
                "the persistent database was deleted with its session — every run re-pays full ingestion")

        let second = try IndexStoreSession(storePath: store, libPath: lib)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let target = root.appendingPathComponent("Sources/RecursionAuditor/RecursionAuditor.swift").path
        #expect(!second.db.symbols(inFilePath: target).isEmpty,
                "a session reopened against the persisted database answered no symbols")
    }

    @Test("releasing a session closes the database back to its 'saved' directory",
          .enabled(if: hasLocalStore, "no swiftbuild index store in this checkout"))
    func releaseSavesTheDatabase() throws {
        let store = try #require(Self.localStore())
        guard let lib = IndexStoreSession.findLibIndexStore() else {
            Issue.record("libIndexStore.dylib not found via active toolchain")
            return
        }
        // A private directory, because the assertion below races any concurrent open of a
        // shared one: `saved` exists only *between* sessions. `SharedIndexStore.drain()`
        // releasing the last reference is covered by the KeyedAsyncCache removeAll tests;
        // this test pins the other half of that chain — release ⇒ clean close.
        let privateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-indexdb-savetest-\(UUID().uuidString)")
        defer {
            // silent: best-effort cleanup of a test-private database directory
            try? FileManager.default.removeItem(at: privateDir)
        }

        try autoreleasepool {
            _ = try IndexStoreSession(storePath: store, libPath: lib, databaseDirectory: privateDir)
        }

        // IndexStoreDB holds the database at a process-unique `v13/p<pid>-…` path while
        // open, and renames it to `v13/saved` only in its destructor. A process that never
        // releases the session exits with the database stranded under the pid name, and
        // the next run discards it — which silently re-ingests every unit, the exact cost
        // persistence exists to remove.
        let saved = privateDir.appendingPathComponent("v13/saved")
        // SAFETY: read-only existence check on a test-private temp directory
        #expect(FileManager.default.fileExists(atPath: saved.path),
                "session release did not close the database cleanly; the next run will discard and re-ingest")
    }

    @Test("an unusable database directory demotes to an ephemeral session that still answers",
          .enabled(if: hasLocalStore, "no swiftbuild index store in this checkout"))
    func unusableDirectoryFallsBackToEphemeral() throws {
        let store = try #require(Self.localStore())
        guard let lib = IndexStoreSession.findLibIndexStore() else {
            Issue.record("libIndexStore.dylib not found via active toolchain")
            return
        }
        // A path *under a regular file* can never be created as a directory.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-indexdb-blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer {
            // silent: best-effort cleanup of a zero-byte temp file; leaking it is harmless
            try? FileManager.default.removeItem(at: blocker)
        }
        let impossible = blocker.appendingPathComponent("db")

        let session = try IndexStoreSession(
            storePath: store, libPath: lib, databaseDirectory: impossible)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let target = root.appendingPathComponent("Sources/RecursionAuditor/RecursionAuditor.swift").path
        #expect(!session.db.symbols(inFilePath: target).isEmpty,
                "the ladder's ephemeral floor should behave exactly like the pre-change session")
    }
}
