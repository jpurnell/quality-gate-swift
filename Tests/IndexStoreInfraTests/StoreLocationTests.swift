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
            // SECURITY: a test fixture; unit names come from the calling test's own literal arguments
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


    @Test("Locating never builds, even when the store lacks test targets")
    func locatingNeverBuildsEvenWhenIncomplete() throws {
        // The earlier "never builds" test used a package with no store at all, so it never
        // reached the branch that could compile. This one sets up the exact shape that
        // triggers enrichment — a swiftbuild store present, tests declared, no test units —
        // and asserts the read-only contract still holds. `doctor` calls this function; a
        // diagnostic must not start a build as a side effect of being asked a question.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        let store = root.appendingPathComponent(".build/out")
        let units = StoreLocator.unitsDirectory(in: store)
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: units.appendingPathComponent("Core-A.o").path, contents: Data())

        #expect(StoreLocator.storeMissesTestTargets(packageRoot: root, store: store))
        _ = StoreLocator.locateExisting(packageRoot: root)

        // A build would have created these; locating must not.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/index-build").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.resolved").path))
    }


    // MARK: - Staleness must not assume the sources live in `Sources/`

    @Test("A store older than the sources is stale even when there is no Sources directory")
    func stalenessIgnoresLayout() throws {
        // SwiftyJSON and Alamofire keep their code in `Source/`. The check compared against a
        // hardcoded `Sources/`, so `newestSwiftMtime` returned nil, the guard was skipped, and
        // the store was treated as fresh forever. Harmless while almost nothing had a
        // `.build/out`; not harmless once that is the primary path.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = root.appendingPathComponent(".build/out")
        let units = StoreLocator.unitsDirectory(in: store)
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: units.appendingPathComponent("Core-A.o").path, contents: Data())
        // Store written in the past; a source edited now.
        let past = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: units.path)
        let swift = source.appendingPathComponent("JSON.swift")
        try "let x = 1\n".write(to: swift, atomically: true, encoding: .utf8)

        #expect(StoreLocator.freshSwiftbuildStore(packageRoot: root) == nil)
    }

    @Test("A store newer than the sources is fresh, whatever the layout")
    func freshStoreAcceptedWithNonStandardLayout() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "let x = 1\n".write(to: source.appendingPathComponent("JSON.swift"),
                                atomically: true, encoding: .utf8)
        let store = root.appendingPathComponent(".build/out")
        let units = StoreLocator.unitsDirectory(in: store)
        try FileManager.default.createDirectory(at: units, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: units.appendingPathComponent("Core-A.o").path, contents: Data())

        #expect(StoreLocator.freshSwiftbuildStore(packageRoot: root)?.path == store.path)
    }


    // MARK: - Is a dedicated store that holds no tests still "fresh"?

    /// A dedicated store (`.build/index-build/index-store`) whose units are exactly `units`,
    /// dated *after* the one source file, so `needsRebuild` has no mtime reason to say yes.
    private func makeFreshDedicatedStore(in root: URL, units: [String], withTestsDirectory: Bool) throws -> URL {
        let fm = FileManager.default
        let source = root.appendingPathComponent("Sources/Core/Thing.swift")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("struct Thing {}".utf8).write(to: source)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: source.path)

        if withTestsDirectory {
            try fm.createDirectory(at: root.appendingPathComponent("Tests/CoreTests"), withIntermediateDirectories: true)
        }

        let store = StoreLocator.managedStore(packageRoot: root)
        let unitsDirectory = StoreLocator.unitsDirectory(in: store)
        try fm.createDirectory(at: unitsDirectory, withIntermediateDirectories: true)
        for unit in units {
            // SECURITY: a test fixture; unit names come from the calling test's own literal arguments
            fm.createFile(atPath: unitsDirectory.appendingPathComponent(unit).path, contents: Data())
        }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000_000)], ofItemAtPath: store.path)
        return store
    }

    @Test("A store newer than the sources but holding no test units is rebuilt")
    func freshStoreWithoutTestsNeedsRebuild() throws {
        // The 2026-10-22 BusinessMathExcel nightly: a 573-unit library-only store, newer than
        // every source, handed to `unreachable`, which then refused to run. Newer-than-sources
        // answered "is it current?" and nobody asked "does it cover the tests?".
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeFreshDedicatedStore(in: root, units: ["Core-ABC.o", "Helpers-DEF.o"], withTestsDirectory: true)

        #expect(StoreLocator.needsRebuild(packageRoot: root, store: store))
    }

    @Test("A fresh store that holds test units is left alone")
    func freshStoreWithTestsIsNotRebuilt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeFreshDedicatedStore(
            in: root, units: ["Core-ABC.o", "CoreTests-DEF.o"], withTestsDirectory: true)

        #expect(!StoreLocator.needsRebuild(packageRoot: root, store: store))
    }

    @Test("A package with no Tests directory is never rebuilt for want of tests")
    func freshStoreWithoutTestsDirectoryIsNotRebuilt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeFreshDedicatedStore(in: root, units: ["Core-ABC.o"], withTestsDirectory: false)

        #expect(!StoreLocator.needsRebuild(packageRoot: root, store: store))
    }

    @Test("A test-less store is not rebuilt again once a test-inclusive build was attempted")
    func attemptedStoreIsNotRebuiltForever() throws {
        // The loop guard. A package whose test target does not compile, or is not named
        // `...Tests`, comes out of a test-inclusive build still without test units. Without a
        // record that the build was tried, `needsRebuild` would say yes on every run and an
        // error would become a permanently slow gate. See FreshStoreWithoutTests.md section 3.1.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeFreshDedicatedStore(in: root, units: ["Core-ABC.o"], withTestsDirectory: true)
        #expect(StoreLocator.needsRebuild(packageRoot: root, store: store))

        StoreLocator.recordTestCoverageAttempt(packageRoot: root, reason: "no unit named *Tests* was produced")

        #expect(!StoreLocator.needsRebuild(packageRoot: root, store: store))
    }
}
