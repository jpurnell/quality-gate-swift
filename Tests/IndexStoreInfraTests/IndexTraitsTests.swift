import Foundation
import Testing
@testable import IndexStoreInfra

// An index store is a record of one build, and a build is a function of its traits as much as
// of its sources. Judged on modification times alone, a store built without SwiftKeychain's
// `OAuth` trait stays "fresh" after the gate starts building with it, and every index-backed
// checker answers questions about code with the adapters compiled out.

/// Removes a temporary fixture, recording a failure instead of discarding it.
private func removeFixture(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("could not remove the fixture at \(url.path): \(error)")
    }
}

@Suite("StoreLocator: index builds use, and are judged by, the configured traits")
struct IndexTraitsTests {

    private func package() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-index-traits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Lib"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Sources/Lib/Lib.swift")
        try "public func f() {}\n".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: source.path)
        return root
    }

    private func managedStore(in root: URL) throws -> URL {
        let store = StoreLocator.managedStore(packageRoot: root)
        try FileManager.default.createDirectory(
            at: StoreLocator.unitsDirectory(in: store), withIntermediateDirectories: true)
        return store
    }

    @Test("The dedicated index build carries the configured traits")
    func dedicatedBuildCarriesTraits() {
        let root = URL(fileURLWithPath: "/tmp/pkg")
        let arguments = StoreLocator.buildArguments(
            packageRoot: root,
            buildPath: StoreLocator.indexBuildDirectory(packageRoot: root),
            store: StoreLocator.managedStore(packageRoot: root),
            includeTests: true,
            traits: ["OAuth", "CLIAuth"])
        #expect(arguments.firstIndex(of: "--traits").map { arguments[$0 + 1] } == "OAuth,CLIAuth")
    }

    @Test("The swiftbuild enrichment build carries the configured traits, and only them")
    func enrichmentCarriesTraits() {
        let root = URL(fileURLWithPath: "/tmp/pkg")
        #expect(StoreLocator.enrichmentArguments(packageRoot: root, traits: ["OAuth"])
            == ["swift", "build", "--build-tests", "--package-path", "/tmp/pkg", "--traits", "OAuth"])
        #expect(StoreLocator.enrichmentArguments(packageRoot: root, traits: [])
            == ["swift", "build", "--build-tests", "--package-path", "/tmp/pkg"])
    }

    @Test("A current store built with no record of traits is current for a run with none")
    func unrecordedStoreServesTheDefaultBuild() throws {
        let root = try package()
        defer { removeFixture(root) }
        let store = try managedStore(in: root)
        #expect(!StoreLocator.needsRebuild(packageRoot: root, store: store, traits: []))
    }

    @Test("A current store built with other traits is rebuilt, and once recorded is not")
    func traitChangeForcesRebuild() throws {
        let root = try package()
        defer { removeFixture(root) }
        let store = try managedStore(in: root)

        #expect(StoreLocator.needsRebuild(packageRoot: root, store: store, traits: ["OAuth"]))

        StoreLocator.recordIndexTraits(["OAuth"], for: store, packageRoot: root)
        #expect(!StoreLocator.needsRebuild(packageRoot: root, store: store, traits: ["OAuth"]))
        #expect(StoreLocator.needsRebuild(packageRoot: root, store: store, traits: []))
    }

    // Through `freshStore` with the flag as an argument, not `ensureFresh` under a set
    // `QG_NO_INDEX_BUILD`: that variable is process-wide, and setting it here made a lock
    // test in another suite skip the lock while this ran.
    @Test("Under --no-index-build, a swiftbuild store built with other traits is not reused")
    func storeWithOtherTraitsIsNotReused() throws {
        let root = try package()
        defer { removeFixture(root) }
        let store = StoreLocator.swiftbuildStorePath(packageRoot: root)
        let units = StoreLocator.unitsDirectory(in: store)
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try Data("unit".utf8).write(to: units.appendingPathComponent("M.o-ABC"))
        let buildPath = StoreLocator.indexBuildDirectory(packageRoot: root)

        #expect(throws: StoreLocator.Error.self) {
            _ = try StoreLocator.freshStore(
                packageRoot: root, buildPath: buildPath, traits: ["OAuth"], noIndexBuild: true)
        }

        StoreLocator.recordIndexTraits(["OAuth"], for: store, packageRoot: root)
        let url = try StoreLocator.freshStore(
            packageRoot: root, buildPath: buildPath, traits: ["OAuth"], noIndexBuild: true)
        #expect(url.path == store.path)
    }
}
