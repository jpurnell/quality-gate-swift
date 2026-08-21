import Foundation
import Testing
@testable import IndexStoreInfra

/// One definition of where an index store lives.
///
/// `Doctor` used to keep its own list — `.build/debug/index/store` and two
/// triple-qualified variants — none of which this locator has ever written to. It
/// therefore reported "none found ... index-backed checkers will degrade to AST-only"
/// on a checkout whose `.build/index-build/index-store` held 2,572 units and was being
/// queried by three checkers in the same run. Two components held different beliefs
/// about one fact and nothing forced them to agree.
@Suite("StoreLocator: canonical store location")
struct StoreLocationTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-store-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("The managed store sits under the index-build directory")
    func managedStoreIsUnderIndexBuild() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = StoreLocator.indexBuildDirectory(packageRoot: root)
        let store = StoreLocator.managedStore(packageRoot: root)

        #expect(directory.lastPathComponent == "index-build")
        #expect(directory.deletingLastPathComponent().lastPathComponent == ".build")
        // `.path`, not `==`: deletingLastPathComponent() leaves a trailing slash,
        // so two URLs naming one directory compare unequal.
        #expect(store.deletingLastPathComponent().path == directory.path)
        #expect(store.lastPathComponent == "index-store")
    }

    @Test("No store on disk means no store reported")
    func absentStoreReportsNil() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(StoreLocator.locateExisting(packageRoot: root) == nil)
    }

    @Test("An existing managed store is found where the locator actually writes it")
    func managedStoreIsFound() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = StoreLocator.managedStore(packageRoot: root)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)

        #expect(StoreLocator.locateExisting(packageRoot: root)?.path == store.path)
    }

    @Test("Locating never builds")
    func locatingNeverBuilds() throws {
        // The diagnostic path must stay read-only: `doctor` reports, it does not compile.
        // If locating ever triggered `ensureFresh`, running it in a clean checkout would
        // start a full index build as a side effect of asking a question.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = StoreLocator.locateExisting(packageRoot: root)

        let buildDirectory = root.appendingPathComponent(".build")
        #expect(!FileManager.default.fileExists(atPath: buildDirectory.path))
    }

    @Test("Unit records live at v5/units inside the store")
    func unitsDirectoryIsCanonical() throws {
        let store = URL(fileURLWithPath: "/tmp/example/.build/out")
        let units = StoreLocator.unitsDirectory(in: store)
        #expect(units.path == "/tmp/example/.build/out/v5/units")
    }

}
