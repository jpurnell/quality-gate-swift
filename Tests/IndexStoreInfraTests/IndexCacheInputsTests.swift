import Foundation
import Testing
@testable import IndexStoreInfra
@testable import QualityGateCore

/// The index store is an input to an index-backed checker, so it belongs in the fingerprint.
///
/// It was not in it. A run with no index produces AST-only findings and caches them against a
/// fingerprint of the *sources*; building the project afterwards changes no source, so the next
/// run replays the degraded result and the cross-module findings never appear. Nothing about
/// that is slow — it is wrong, which is the one way a cache must not fail. `SourceCacheInputs`
/// says so itself: "under-specifying an input is the only way a cache can be *wrong* rather
/// than merely slow."
@Suite("Index store participates in the cache fingerprint")
struct IndexCacheInputsTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-idx-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("No index and an index produce different salts")
    func indexPresenceChangesTheSalt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = Configuration()

        let withoutIndex = SourceCacheInputs.wholeSourceAndIndex(
            projectRoot: root, configuration: configuration)

        let units = StoreLocator.unitsDirectory(in: StoreLocator.managedStore(packageRoot: root))
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)

        let withIndex = SourceCacheInputs.wholeSourceAndIndex(
            projectRoot: root, configuration: configuration)

        #expect(withoutIndex.salt != withIndex.salt)
    }

    @Test("The index-aware salt still differs from the plain one")
    func indexAwareSaltDiffersFromPlain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = Configuration()

        let plain = SourceCacheInputs.wholeSource(projectRoot: root, configuration: configuration)
        let indexed = SourceCacheInputs.wholeSourceAndIndex(
            projectRoot: root, configuration: configuration)

        // Same files, different salt: an index-backed checker must not share a cache entry
        // with the plain fingerprint it used to compute.
        #expect(plain.files == indexed.files)
        #expect(plain.salt != indexed.salt)
    }

    @Test("Two calls with an unchanged store agree")
    func stableWhenNothingChanges() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = Configuration()
        let units = StoreLocator.unitsDirectory(in: StoreLocator.managedStore(packageRoot: root))
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)

        let first = SourceCacheInputs.wholeSourceAndIndex(projectRoot: root, configuration: configuration)
        let second = SourceCacheInputs.wholeSourceAndIndex(projectRoot: root, configuration: configuration)

        #expect(first.salt == second.salt)
    }
}
