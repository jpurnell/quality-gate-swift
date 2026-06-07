import Foundation
import IndexStoreDB
import os

// Justification: IndexStoreDB is immutable after init; all queries are read-only.
extension IndexStoreDB: @retroactive @unchecked Sendable {}

/// Wraps IndexStoreDB initialization into a reusable session.
///
/// Handles the boilerplate of creating a temporary database directory,
/// loading the `libIndexStore` dylib, opening the index store, and
/// polling for changes. Checkers receive a ready-to-query `IndexStoreDB`
/// instance via `db`.
public final class IndexStoreSession: Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "IndexStoreSession")

    /// The ready-to-query IndexStoreDB instance opened by this session.
    public let db: IndexStoreDB
    private let tempDir: URL

    /// Opens an IndexStoreDB session.
    ///
    /// - Parameters:
    ///   - storePath: Path to the index store (e.g. `.build/index-build/index-store`).
    ///   - libPath: Path to `libIndexStore.dylib`.
    /// - Throws: If the library cannot be loaded or the store cannot be opened.
    public init(storePath: URL, libPath: URL) throws {
        let lib = try IndexStoreLibrary(dylibPath: libPath.path)
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("quality-gate-indexdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbPath, withIntermediateDirectories: true) // SAFETY: CLI tool creates temp directory for index DB
        self.tempDir = dbPath

        self.db = try IndexStoreDB(
            storePath: storePath.path,
            databasePath: dbPath.path,
            library: lib,
            waitUntilDoneInitializing: true,
            listenToUnitEvents: false
        )
        db.pollForUnitChangesAndWait()
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: tempDir)
        } catch {
            Self.logger.warning("Failed to clean up temp directory \(self.tempDir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Locates `libIndexStore.dylib` from the active Xcode toolchain.
    public static func findLibIndexStore() -> URL? {
        let candidates = [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib",
            "/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { // SAFETY: CLI tool checks hardcoded toolchain library paths
                return URL(fileURLWithPath: path)
            }
        }
        return xcrunLibIndexStore()
    }

    private static func xcrunLibIndexStore() -> URL? {
        let pipe = Pipe()
        // SAFETY: runs xcrun --find swift to locate the toolchain libIndexStore
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swift"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.warning("Failed to run xcrun to locate libIndexStore: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        guard let swiftPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let toolchainLib = URL(fileURLWithPath: swiftPath)
            .deletingLastPathComponent() // bin
            .deletingLastPathComponent() // usr
            .appendingPathComponent("usr/lib/libIndexStore.dylib")
        if FileManager.default.fileExists(atPath: toolchainLib.path) { // SAFETY: CLI tool checks local toolchain library path
            return toolchainLib
        }
        return nil
    }
}
