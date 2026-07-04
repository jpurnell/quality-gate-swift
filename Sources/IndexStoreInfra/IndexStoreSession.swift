import Foundation
import IndexStoreDB
#if canImport(os)
import os
#endif

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
        let pipe = Pipe()
        // SAFETY: callers pass hardcoded executable paths (xcode-select, xcrun)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.warning("Failed to run \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : nil
    }
}
