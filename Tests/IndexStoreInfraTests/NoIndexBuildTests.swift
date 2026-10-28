import Foundation
import Testing
@testable import IndexStoreInfra

/// Verifies `--no-index-build` (`QG_NO_INDEX_BUILD`): when no fresh index store
/// exists, `ensureFresh` throws `indexBuildSkipped` instead of compiling, so
/// index-backed checkers degrade to AST-only rather than building the project.
///
/// The flag is passed as an argument rather than set with `setenv`: the variable is
/// process-wide, and setting it made `IndexBuildLockTests` in another suite skip its lock.
@Suite("StoreLocator --no-index-build")
struct NoIndexBuildTests {

    private func makeEmptyPackage() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-noindexbuild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        return root
    }

    @Test("With the flag set and no store, ensureFresh throws indexBuildSkipped (never builds)")
    func throwsInsteadOfBuilding() throws {
        let root = try makeEmptyPackage()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: StoreLocator.Error.self) {
            _ = try StoreLocator.ensureFresh(packageRoot: root, traits: [], noIndexBuild: true)
        }
        // And it must NOT have started a build.
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".build/index-build").path))
    }

    @Test("With the flag set but a fresh swiftbuild store present, ensureFresh returns it")
    func reusesExistingStoreEvenWithFlag() throws {
        let root = try makeEmptyPackage()
        defer { try? FileManager.default.removeItem(at: root) }

        // Fabricate a fresh .build/out store (as swiftbuild would emit).
        let units = root.appendingPathComponent(".build/out/v5/units", isDirectory: true)
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        try Data("unit".utf8).write(to: units.appendingPathComponent("M.o-ABC"))

        let url = try StoreLocator.ensureFresh(packageRoot: root, traits: [], noIndexBuild: true)
        #expect(url.path == root.appendingPathComponent(".build/out").path)
    }
}
