import Foundation
import Testing
@testable import IndexStoreInfra

/// Appending a path component must not depend on the filesystem.
///
/// These tests pass trivially on Darwin, which never stats, and are the whole point on Linux,
/// where `appendingPathComponent(_:)` does. They are written to fail on the platform that has
/// the behaviour rather than to be skipped there — a Darwin-only assertion is how the
/// divergence survived in the first place.
@Suite("Deterministic path appending")
struct DeterministicPathsTests {

    private static func temporaryDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("det-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The exact shape of the eight failures: the expected URL is built before the directory
    /// exists, the actual one after it does.
    @Test("The same component appends identically before and after the directory exists")
    func stableAcrossDirectoryCreation() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = root.appendingPathComponentUnstatted("Test.xcodeproj")
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        let after = root.appendingPathComponentUnstatted("Test.xcodeproj")

        #expect(before == after)
        #expect(before.standardizedFileURL == after.standardizedFileURL)
        #expect(!after.absoluteString.hasSuffix("/"))
    }

    @Test("A multi-component path appends without a trailing slash")
    func multiComponentIsStable() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = root.appendingPathComponentUnstatted("Index.noindex/DataStore")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)

        #expect(root.appendingPathComponentUnstatted("Index.noindex/DataStore") == store)
        #expect(!store.absoluteString.hasSuffix("/"))
        #expect(store.lastPathComponent == "DataStore")
    }

    /// The path still resolves: `isDirectory: false` is about the trailing slash, not a claim
    /// that the component names a file.
    @Test("A directory appended this way is still reachable as a directory")
    func stillUsableAsDirectory() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponentUnstatted("Bundle.xcworkspace")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
