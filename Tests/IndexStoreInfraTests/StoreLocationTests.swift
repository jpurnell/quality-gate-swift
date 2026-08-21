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


    // MARK: - Indexing test targets

    @Test("The index build asks for test targets")
    func indexBuildIncludesTests() {
        // `swift build` does not compile tests, so a recursion bug in a suite was decided
        // syntactically — and eight of the ten self-call findings left in a 22-package
        // survey were in test files, including one confirmed false positive that the
        // index would have resolved. A test that recurses without a base case hangs a run
        // exactly as thoroughly as a tool does.
        let arguments = StoreLocator.buildArguments(
            packageRoot: URL(fileURLWithPath: "/tmp/pkg"),
            buildPath: URL(fileURLWithPath: "/tmp/pkg/.build/index-build"),
            store: URL(fileURLWithPath: "/tmp/pkg/.build/index-build/index-store"),
            includeTests: true
        )
        #expect(arguments.contains("--build-tests"))
        #expect(arguments.contains("-index-store-path"))
    }

    @Test("The fallback build omits test targets")
    func fallbackBuildOmitsTests() {
        // Where tests do not compile, indexing them would lose the *whole* index rather
        // than part of it. The retry keeps the sources indexed.
        let arguments = StoreLocator.buildArguments(
            packageRoot: URL(fileURLWithPath: "/tmp/pkg"),
            buildPath: URL(fileURLWithPath: "/tmp/pkg/.build/index-build"),
            store: URL(fileURLWithPath: "/tmp/pkg/.build/index-build/index-store"),
            includeTests: false
        )
        #expect(!arguments.contains("--build-tests"))
        #expect(arguments.contains("-index-store-path"))
    }

    @Test("Both forms still target the same store and package")
    func bothFormsAgreeOnPaths() {
        let root = URL(fileURLWithPath: "/tmp/pkg")
        let store = StoreLocator.managedStore(packageRoot: root)
        let build = StoreLocator.indexBuildDirectory(packageRoot: root)
        for includeTests in [true, false] {
            let arguments = StoreLocator.buildArguments(
                packageRoot: root, buildPath: build, store: store, includeTests: includeTests)
            #expect(arguments.contains(store.path))
            #expect(arguments.contains(root.path))
        }
    }


    // MARK: - Does the store cover test targets?

    private func makeStore(in root: URL, units: [String]) throws -> URL {
        let store = root.appendingPathComponent(".build/out")
        let units_ = StoreLocator.unitsDirectory(in: store)
        try FileManager.default.createDirectory(at: units_, withIntermediateDirectories: true)
        for unit in units {
            FileManager.default.createFile(atPath: units_.appendingPathComponent(unit).path, contents: Data())
        }
        return store
    }

    @Test("A package with no tests is never missing test coverage")
    func packageWithoutTestsIsComplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(in: root, units: ["Core-ABC.o"])

        #expect(!StoreLocator.storeMissesTestTargets(packageRoot: root, store: store))
    }

    @Test("A store holding test-module units covers them")
    func storeWithTestUnitsIsComplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        let store = try makeStore(in: root, units: ["Core-ABC.o", "CoreTests-DEF.o"])

        #expect(!StoreLocator.storeMissesTestTargets(packageRoot: root, store: store))
    }

    @Test("A store built without tests is missing them")
    func storeWithoutTestUnitsIsIncomplete() throws {
        // swiftbuild index-while-builds only what a normal `swift build` compiles, which
        // excludes test targets. That store is fresh and useful and still cannot answer a
        // question about a test file.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        let store = try makeStore(in: root, units: ["Core-ABC.o", "Helpers-DEF.o"])

        #expect(StoreLocator.storeMissesTestTargets(packageRoot: root, store: store))
    }

    @Test("An unreadable store counts as missing test coverage")
    func unreadableStoreIsIncomplete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)

        #expect(StoreLocator.storeMissesTestTargets(
            packageRoot: root, store: root.appendingPathComponent(".build/out")))
    }

}
