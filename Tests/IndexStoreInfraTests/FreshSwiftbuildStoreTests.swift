import Foundation
import Testing
@testable import IndexStoreInfra

/// Unit tests for `StoreLocator.freshSwiftbuildStore`, the fast path that reuses
/// swiftbuild's own `.build/out` index store instead of running a second full
/// compile. Uses on-disk fixtures with controlled mtimes.
@Suite("StoreLocator.freshSwiftbuildStore")
struct FreshSwiftbuildStoreTests {

    /// Builds a temp package root with the given store/source state and returns its URL.
    private func makeRoot(
        withUnits: Bool,
        emptyUnits: Bool = false,
        sourceNewerThanStore: Bool
    ) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("qg-sbstore-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)

        let past = Date(timeIntervalSince1970: 1_000_000)
        let future = Date(timeIntervalSince1970: 2_000_000)

        if withUnits {
            let units = root.appendingPathComponent(".build/out/v5/units", isDirectory: true)
            try fm.createDirectory(at: units, withIntermediateDirectories: true)
            if !emptyUnits {
                let unit = units.appendingPathComponent("SomeModule.o-ABC123")
                try Data("unit".utf8).write(to: unit)
            }
            // Store recorded at `past`; source is either older or newer than that.
            try fm.setAttributes([.modificationDate: past], ofItemAtPath: units.path)
        }

        let source = sources.appendingPathComponent("Thing.swift")
        try Data("struct Thing {}".utf8).write(to: source)
        let sourceDate = sourceNewerThanStore ? future : Date(timeIntervalSince1970: 500_000)
        try fm.setAttributes([.modificationDate: sourceDate], ofItemAtPath: source.path)

        return root
    }

    @Test("Absent store → nil (native toolchain fallthrough)")
    func absentStore() throws {
        let root = try makeRoot(withUnits: false, sourceNewerThanStore: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(StoreLocator.freshSwiftbuildStore(packageRoot: root) == nil)
    }

    @Test("Present + current store → returns .build/out")
    func freshStore() throws {
        let root = try makeRoot(withUnits: true, sourceNewerThanStore: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = StoreLocator.freshSwiftbuildStore(packageRoot: root)
        #expect(result?.lastPathComponent == "out")
        #expect(result?.path == root.appendingPathComponent(".build/out").path)
    }

    @Test("Present but a source is newer → nil (stale, force rebuild)")
    func staleStore() throws {
        let root = try makeRoot(withUnits: true, sourceNewerThanStore: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(StoreLocator.freshSwiftbuildStore(packageRoot: root) == nil)
    }

    @Test("Empty units directory → nil (not a real store)")
    func emptyUnits() throws {
        let root = try makeRoot(withUnits: true, emptyUnits: true, sourceNewerThanStore: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(StoreLocator.freshSwiftbuildStore(packageRoot: root) == nil)
    }
}
