import Foundation
import QualityGateCore
import IndexStoreDB
#if canImport(os)
import os
#endif

// Justification: IndexStoreDB is immutable after init; all queries are read-only.
extension IndexStoreDB: @retroactive @unchecked Sendable {}

/// Wraps IndexStoreDB initialization into a reusable session.
///
/// Loads the `libIndexStore` dylib, opens the index store against a **persistent**
/// database directory derived from the store's own location, and polls for changes.
/// Checkers receive a ready-to-query `IndexStoreDB` instance via `db`.
///
/// The database is IndexStoreDB's LMDB ingestion of the store's unit records. It
/// persists across runs — deliberately — so `pollForUnitChangesAndWait()` processes
/// only units whose files changed, instead of re-ingesting every unit into a throwaway
/// temp directory on each run (measured at ~11s of a 15s `recursion` run on this
/// package's 3,402 units; see `IngestionIsNotAnalysis.md`). It lives beside the store,
/// so whatever wipes the store wipes the database built from it, and it is safe to
/// delete at any time: the next session rebuilds it in full.
///
/// When the persistent directory cannot be used, the session demotes — wipe and retry
/// once, then fall back to an ephemeral temp directory, which is the pre-persistence
/// behaviour and the ladder's floor.
public final class IndexStoreSession: Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "IndexStoreSession")

    /// The ready-to-query IndexStoreDB instance opened by this session.
    public let db: IndexStoreDB
    /// Set only when the session demoted to a throwaway database; removed in `deinit`.
    private let ephemeralDir: URL?

    /// The persistent database directory for `storePath`: a sibling named
    /// `quality-gate-indexdb-<store name>`.
    ///
    /// The single definition of this path, in the `StoreLocator` tradition. Co-location
    /// is the coherence property: a `.build` wipe (or Xcode deleting DerivedData)
    /// necessarily destroys the database together with the store it was ingested from,
    /// so the database can never outlive — or answer for — a store that is gone.
    public static func databaseDirectory(for storePath: URL) -> URL {
        storePath.deletingLastPathComponent()
            .appendingPathComponent("quality-gate-indexdb-\(storePath.lastPathComponent)")
    }

    /// Opens an IndexStoreDB session with the persistent database for `storePath`.
    ///
    /// - Parameters:
    ///   - storePath: Path to the index store (e.g. `.build/index-build/index-store`).
    ///   - libPath: Path to `libIndexStore.dylib`.
    /// - Throws: If the library cannot be loaded or the store cannot be opened.
    public convenience init(storePath: URL, libPath: URL) throws {
        try self.init(
            storePath: storePath,
            libPath: libPath,
            databaseDirectory: Self.databaseDirectory(for: storePath)
        )
    }

    /// Internal seam: opens against an explicit database directory.
    init(storePath: URL, libPath: URL, databaseDirectory: URL) throws {
        let lib = try IndexStoreLibrary(dylibPath: libPath.path)

        if let persistent = Self.openPersistent(
            storePath: storePath, library: lib, databaseDirectory: databaseDirectory) {
            self.db = persistent
            self.ephemeralDir = nil
            return
        }

        // The ladder's floor: a throwaway database, exactly the pre-persistence behaviour.
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("quality-gate-indexdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbPath, withIntermediateDirectories: true) // SAFETY: CLI tool creates temp directory for index DB
        self.ephemeralDir = dbPath
        self.db = try Self.open(storePath: storePath, library: lib, databasePath: dbPath)
    }

    /// Opens and polls an `IndexStoreDB` at `databasePath`.
    private static func open(
        storePath: URL, library: IndexStoreLibrary, databasePath: URL
    ) throws -> IndexStoreDB {
        let db = try IndexStoreDB(
            storePath: storePath.path,
            databasePath: databasePath.path,
            library: library,
            waitUntilDoneInitializing: true,
            listenToUnitEvents: false
        )
        db.pollForUnitChangesAndWait()
        return db
    }

    /// Rungs 1 and 2 of the ladder: open persistent; on failure wipe and retry once.
    ///
    /// The open-and-poll is serialized across processes with the same `flock(2)` pattern
    /// `StoreLocator` uses for index builds, because the first ingestion is a heavy write
    /// burst two concurrent gate runs should not interleave. The lock file is a *sibling*
    /// of the database directory, not inside it — the wipe rung deletes the directory,
    /// and a lock file deleted mid-hold silently stops excluding the next process.
    /// Queries after init are read-only and unserialized.
    private static func openPersistent(
        storePath: URL, library: IndexStoreLibrary, databaseDirectory: URL
    ) -> IndexStoreDB? {
        let lockURL = databaseDirectory.deletingLastPathComponent()
            .appendingPathComponent(databaseDirectory.lastPathComponent + ".lock")
        do {
            var opened: IndexStoreDB?
            try StoreLocator.withExclusiveLock(at: lockURL) {
                do {
                    try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true) // SAFETY: CLI tool creates the persistent index DB directory beside the store
                    opened = try open(
                        storePath: storePath, library: library, databasePath: databaseDirectory)
                } catch {
                    logger.warning("persistent index DB at \(databaseDirectory.path, privacy: .public) failed to open (\(error.localizedDescription, privacy: .public)); wiping and retrying once")
                    try FileManager.default.removeItem(at: databaseDirectory) // SAFETY: CLI tool removes its own corrupt index DB directory
                    try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true) // SAFETY: CLI tool recreates the persistent index DB directory
                    opened = try open(
                        storePath: storePath, library: library, databasePath: databaseDirectory)
                }
            }
            return opened
        } catch {
            logger.warning("persistent index DB unusable at \(databaseDirectory.path, privacy: .public); demoting to an ephemeral database: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    deinit {
        guard let ephemeralDir else { return }
        do {
            try FileManager.default.removeItem(at: ephemeralDir)
        } catch {
            Self.logger.warning("Failed to clean up temp directory \(ephemeralDir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Locates `libIndexStore.dylib`, preferring the **active** toolchain.
    ///
    /// The library must match the toolchain that produced the index store, or
    /// cross-module lookups silently return nothing. Earlier this method returned
    /// the first *existing* hardcoded path — which, on a machine whose selected
    /// toolchain is an Xcode-beta with no `/Applications/Xcode.app`, resolved to a
    /// mismatched Command Line Tools library. It now resolves from the active
    /// developer directory (`xcode-select`) first and only falls back to hardcoded
    /// paths as a last resort.
    public static func findLibIndexStore() -> URL? {
        // 1. Active toolchain via xcode-select (respects the selected Xcode/beta).
        if let active = activeToolchainLibIndexStore() { return active }
        // 2. Active toolchain via `xcrun --find swift`.
        if let viaXcrun = xcrunLibIndexStore() { return viaXcrun }
        // 3. Last-resort hardcoded fallbacks.
        let fallbacks = [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
            "/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib",
        ]
        for path in fallbacks where FileManager.default.fileExists(atPath: path) { // SAFETY: CLI tool checks hardcoded toolchain library paths
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Resolves `libIndexStore.dylib` from the active developer dir (`xcode-select -p`).
    private static func activeToolchainLibIndexStore() -> URL? {
        guard let developerDir = captureStdout("/usr/bin/xcode-select", ["-p"]) else { return nil }
        let lib = URL(fileURLWithPath: developerDir)
            .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib")
        // SAFETY: CLI tool checks local toolchain library path
        return FileManager.default.fileExists(atPath: lib.path) ? lib : nil
    }

    private static func xcrunLibIndexStore() -> URL? {
        guard let swiftPath = captureStdout("/usr/bin/xcrun", ["--find", "swift"]) else { return nil }
        let toolchainLib = URL(fileURLWithPath: swiftPath)
            .deletingLastPathComponent() // .../usr/bin
            .deletingLastPathComponent() // .../usr
            .appendingPathComponent("lib/libIndexStore.dylib")
        // SAFETY: CLI tool checks local toolchain library path
        return FileManager.default.fileExists(atPath: toolchainLib.path) ? toolchainLib : nil
    }

    /// Runs `executable` with `arguments` and returns trimmed stdout, or nil on failure.
    private static func captureStdout(_ executable: String, _ arguments: [String]) -> String? {
        // Through the kernel. This runs during index setup, before anything else can report a
        // problem, so a hang here is a gate that never starts rather than one that fails.
        do {
            // SAFETY: callers pass hardcoded executable paths (xcode-select, xcrun)
            let result = try ProcessRunner.run(executable, arguments: arguments, timeout: 60)
            guard result.exitCode == 0 else { return nil }
            let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? nil : output
        } catch {
            logger.warning("Failed to run \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
