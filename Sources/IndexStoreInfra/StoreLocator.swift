import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(os)
import os
#endif
import QualityGateCore

/// Locates and ensures freshness of compiler index stores for Swift projects.
///
/// Supports SwiftPM (auto-build), Xcode (DerivedData lookup), and
/// xcworkspace project types. Plain directories return `nil`.
public enum StoreLocator {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "StoreLocator")

    /// Errors thrown during index-store location or build operations.
    public enum Error: LocalizedError {
        case buildFailed(String)
        /// No fresh index store exists and `--no-index-build` (`QG_NO_INDEX_BUILD`) forbids
        /// building one. Index-backed checkers catch this and degrade to AST-only analysis.
        case indexBuildSkipped
        /// A human-readable description of the failure.
        public var errorDescription: String? {
            switch self {
            case .buildFailed(let s):
                return "swift build (index-store) failed: \(s)"
            case .indexBuildSkipped:
                return "no fresh index store and --no-index-build set; skipping index-backed analysis"
            }
        }
    }

    /// A located index store, plus whether we believe it is stale relative
    /// to the current source tree.
    public struct LocatedStore: Sendable {
        /// File-system URL of the discovered index store directory.
        public var url: URL
        /// Whether the store is outdated relative to current sources.
        public var isStale: Bool
        /// The measurement backing `isStale`, when one could be taken.
        ///
        /// Nil only for stores built through the legacy `init(url:isStale:)`, where the caller
        /// asserted a verdict instead of measuring one. A checker that wants to report *why*
        /// a store is stale — the two timestamps a barrier must carry — reads this.
        public var measurement: IndexFreshnessMeasurement?

        /// Creates a located store with an asserted staleness flag and no measurement.
        public init(url: URL, isStale: Bool) {
            self.url = url
            self.isStale = isStale
            self.measurement = nil
        }

        /// Creates a located store whose staleness is derived from a measurement.
        ///
        /// - Parameters:
        ///   - url: The store directory.
        ///   - measurement: The comparison of index units against sources. Only
        ///     `.measured` can make a store stale: an index that could not be dated is
        ///     unmeasured, which is a different statement from current.
        public init(url: URL, measurement: IndexFreshnessMeasurement) {
            self.url = url
            self.measurement = measurement
            switch measurement {
            case .measured(let freshness): self.isStale = freshness.isStale
            case .noIndexUnits, .noSources: self.isStale = false
            }
        }
    }

    /// Locate an index store appropriate to a `ProjectKind`.
    ///
    /// - Parameters:
    ///   - projectKind: The detected project layout.
    ///   - excludePatterns: Patterns whose files must not count toward the source timestamp,
    ///     so an excluded file cannot make an index look stale.
    /// - Returns: The located store, or nil when the layout has none.
    public static func locate(
        projectKind: ProjectKind,
        excludePatterns: [String] = []
    ) throws -> LocatedStore? {
        switch projectKind {
        case .swiftPM(let packageRoot):
            let url = try ensureFresh(packageRoot: packageRoot)
            // Measured, not asserted. `ensureFresh` cannot guarantee what this claims:
            // `needsRebuild` stats the top-level store directory, whose mtime does not move
            // when a unit nested under `v5/units` is rewritten — on this repository that
            // directory sat eight days behind the units inside it.
            return located(store: url, projectRoot: packageRoot, excludePatterns: excludePatterns)

        case .xcode(let projectFile, let root):
            return locateXcode(file: projectFile, root: root, excludePatterns: excludePatterns)

        case .xcworkspace(let workspaceFile, let root):
            return locateXcode(file: workspaceFile, root: root, excludePatterns: excludePatterns)

        case .plain:
            return nil
        }
    }

    /// Builds a `LocatedStore` by measuring `store` against the sources under `projectRoot`.
    ///
    /// The whole project tree is walked, not a named list of target directories. SwiftPM
    /// target paths are configurable, so `Sources`/`Tests` is a guess about a layout rather
    /// than a fact about one — and a guess that is wrong in the *fresh* direction fails
    /// silently, which is the failure this whole type exists to remove. `SourceWalker` already
    /// owns this project's single definition of what is not source (`.build`, `.git`,
    /// `DerivedData`, Xcode containers, and the rest), so dependency checkouts and build
    /// products stay out without a second skip list being invented here.
    ///
    /// Test sources are in scope, and must be: `unreachable` roots every symbol in a test
    /// target because the test runner is the implicit entry point, so adding or deleting a
    /// test is precisely the edit that changes reachability. Measuring against product code
    /// alone would leave that edit unable to invalidate the index it changes the meaning of.
    ///
    /// - Parameters:
    ///   - store: The index store directory, as returned by the locator — never a fixed path,
    ///     since a package can hold several stores of differing ages and only the one actually
    ///     read says anything about the answer.
    ///   - projectRoot: The project root to walk.
    ///   - excludePatterns: Patterns excluded from the source timestamp.
    /// - Returns: A store carrying its measurement.
    static func located(
        store: URL,
        projectRoot: URL,
        excludePatterns: [String]
    ) -> LocatedStore {
        LocatedStore(
            url: store,
            measurement: IndexFreshness.measure(
                storeURL: store,
                sourceRoots: [projectRoot],
                excludePatterns: excludePatterns
            )
        )
    }

    private static func locateXcode(
        file: URL,
        root: URL,
        excludePatterns: [String]
    ) -> LocatedStore? {
        let name = file.deletingPathExtension().lastPathComponent
        guard let url = locateInDerivedData(
            projectName: name,
            projectPath: file,
            derivedDataRoot: defaultDerivedDataRoot()
        ) else { return nil }
        // Xcode's DerivedData store keeps its units at the same `v5/units` path, so the same
        // measurement applies. It previously used `isIndexStoreStale`, which compares against
        // the store directory and so cannot see a rewritten unit — the defect that made the
        // SwiftPM path's asserted freshness invisible for as long as it was.
        return located(store: url, projectRoot: root, excludePatterns: excludePatterns)
    }

    // MARK: - Xcode scheme parsing

    /// Parse the JSON output of `xcodebuild -list -json` and return the
    /// first scheme.
    public static func firstScheme(fromXcodebuildListJSON data: Data) throws -> String {
        struct Listing: Decodable {
            struct Container: Decodable { let schemes: [String] }
            let project: Container?
            let workspace: Container?
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let schemes = listing.project?.schemes ?? listing.workspace?.schemes ?? []
        guard let first = schemes.first else {
            throw Error.buildFailed("xcodebuild -list reported no schemes")
        }
        return first
    }

    /// Configuration for the optional Xcode auto-build path.
    public struct XcodebuildOptions: Sendable {
        /// Optional Xcode scheme name; auto-detected from the project when nil.
        public var scheme: String?
        /// Build destination platform string (e.g. "generic/platform=macOS").
        public var destination: String
        /// Build configuration name, typically "Debug" or "Release".
        public var configuration: String
        /// Directory where xcodebuild writes its DerivedData output.
        public var derivedDataPath: URL

        /// Creates xcodebuild options with the given parameters.
        public init(
            scheme: String? = nil,
            destination: String = "generic/platform=macOS",
            configuration: String = "Debug",
            derivedDataPath: URL
        ) {
            self.scheme = scheme
            self.destination = destination
            self.configuration = configuration
            self.derivedDataPath = derivedDataPath
        }

        /// Returns default xcodebuild options using a `.build/xcode-derived` subdirectory under `rootURL`.
        public static func defaults(rootURL: URL) -> XcodebuildOptions {
            XcodebuildOptions(
                derivedDataPath: rootURL.appendingPathComponent(".build/xcode-derived")
            )
        }
    }

    /// Drive `xcodebuild build` to produce a fresh index store.
    public static func runXcodebuild(
        projectKind: ProjectKind,
        options: XcodebuildOptions
    ) throws -> URL {
        let (flag, file): (String, URL)
        switch projectKind {
        case .xcode(let f, _):       (flag, file) = ("-project", f)
        case .xcworkspace(let f, _): (flag, file) = ("-workspace", f)
        case .swiftPM, .plain:
            throw Error.buildFailed("runXcodebuild called for non-Xcode project")
        }

        let scheme = try options.scheme ?? listFirstScheme(flag: flag, filePath: file)

        let result = try ProcessRunner.run(
            "/usr/bin/env",
            arguments: [
                "xcodebuild", "build",
                flag, file.path,
                "-scheme", scheme,
                "-configuration", options.configuration,
                "-destination", options.destination,
                "-derivedDataPath", options.derivedDataPath.path,
                "COMPILER_INDEX_STORE_ENABLE=YES",
            ],
            mergeStderr: true
        )
        if result.exitCode != 0 {
            let tail = result.stdout.suffix(2000)
            throw Error.buildFailed("xcodebuild build exited \(result.exitCode): \(tail)")
        }

        let store = options.derivedDataPath.appendingPathComponent("Index.noindex/DataStore")
        guard FileManager.default.fileExists(atPath: store.path) else { // SAFETY: CLI tool checks local index store path
            throw Error.buildFailed("xcodebuild succeeded but no index store at \(store.path)")
        }
        return store
    }

    private static func listFirstScheme(flag: String, filePath: URL) throws -> String {
        let result = try ProcessRunner.run(
            "/usr/bin/env",
            arguments: ["xcodebuild", "-list", "-json", flag, filePath.path]
        )
        if result.exitCode != 0 {
            throw Error.buildFailed("xcodebuild -list exited \(result.exitCode)")
        }
        guard let data = result.stdout.data(using: .utf8) else {
            throw Error.buildFailed("xcodebuild -list produced non-UTF-8 output")
        }
        return try firstScheme(fromXcodebuildListJSON: data)
    }

    // MARK: - DerivedData location

    /// Find a usable Xcode-emitted index store under `derivedDataRoot`.
    public static func locateInDerivedData(
        projectName: String,
        projectPath: URL,
        derivedDataRoot: URL
    ) -> URL? {
        let fm = FileManager.default
        let sanitized = projectName.replacingOccurrences(of: " ", with: "_")
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: derivedDataRoot.path) // SAFETY: CLI tool scans local DerivedData
        } catch {
            logger.warning("Could not list DerivedData at \(derivedDataRoot.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        var matches: [(URL, Date)] = []
        for entry in entries {
            guard let dash = entry.lastIndex(of: "-") else { continue }
            let prefix = String(entry[..<dash])
            guard prefix == sanitized else { continue }

            let entryDir = derivedDataRoot.appendingPathComponent(entry)
            let store = entryDir.appendingPathComponent("Index.noindex/DataStore")
            guard fm.fileExists(atPath: store.path) else { continue } // SAFETY: CLI tool checks local index store path

            let infoPlist = entryDir.appendingPathComponent("info.plist")
            do {
                let data = try Data(contentsOf: infoPlist)
                let plist: Any
                do {
                    plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                } catch {
                    logger.warning("Malformed plist at \(infoPlist.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    plist = [:] as [String: Any]
                }
                if let dict = plist as? [String: Any],
                   let ws = dict["WorkspacePath"] as? String {
                    let canonicalWS = URL(fileURLWithPath: ws).resolvingSymlinksInPath().path
                    let canonicalProj = projectPath.resolvingSymlinksInPath().path
                    if canonicalWS != canonicalProj { continue }
                }
            } catch {
                logger.warning("Could not read info.plist at \(infoPlist.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            let mtime: Date
            do {
                let attrs = try fm.attributesOfItem(atPath: store.path) // SAFETY: CLI tool reads local index store attributes
                mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            } catch {
                logger.warning("Could not read attributes for \(store.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                mtime = .distantPast
            }
            matches.append((store, mtime))
        }
        return matches.max(by: { $0.1 < $1.1 })?.0
    }

    // MARK: - Staleness checking

    /// Conservative staleness check: store is stale if any `.swift` file
    /// under `sourcesRoot` is newer than the store directory.
    public static func isIndexStoreStale(store: URL, sourcesRoot: URL) -> Bool {
        guard let storeMtime = mtime(of: store) else { return true }
        guard let newest = newestSwiftMtime(under: sourcesRoot) else { return false }
        return newest > storeMtime
    }

    /// Returns the standard Xcode DerivedData directory for the current user.
    public static func defaultDerivedDataRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    // MARK: - Where the store lives

    /// The directory the gate builds its own index store into.
    ///
    /// The single definition of this path. Anything that needs to know where a store is —
    /// the locator, the freshness probe, `doctor` — asks here rather than composing the
    /// path itself. `Doctor` used to keep its own list of three, none of which this type
    /// has ever written to, and so reported "none found" against a store holding 2,572
    /// units that three checkers were querying in the same run.
    public static func indexBuildDirectory(packageRoot: URL) -> URL {
        packageRoot.appendingPathComponent(".build/index-build")
    }

    /// The unit records inside an index store.
    ///
    /// `v5/units` is the layout every consumer needs — freshness is judged on it, unit
    /// counts are read from it — and it was being composed independently in three places.
    /// One of them measured store *age* on the store root instead, which reported a
    /// current store as 407 hours stale.
    public static func unitsDirectory(in store: URL) -> URL {
        store.appendingPathComponent("v5/units", isDirectory: true)
    }

    /// The index store the gate builds and owns for `packageRoot`.
    public static func managedStore(packageRoot: URL) -> URL {
        indexBuildDirectory(packageRoot: packageRoot).appendingPathComponent("index-store")
    }

    /// The store an index-backed checker would query right now, or `nil` if there is none.
    ///
    /// Consults the same candidates as ``ensureFresh(packageRoot:)``, in the same order —
    /// swiftbuild's own store first, then the managed one — and **never compiles**. A
    /// diagnostic must be able to ask where the store is without a full index build
    /// happening as a side effect of the question.
    ///
    /// Note that an existing store is not necessarily a *useful* one: a store can hold
    /// nothing but Clang module units because its build failed before reaching the
    /// package's own Swift code. Callers that care report unit counts, not mere existence.
    public static func locateExisting(packageRoot: URL) -> URL? {
        if let swiftbuildStore = freshSwiftbuildStore(packageRoot: packageRoot) {
            // Fresh, but possibly source-only. Enriching costs an incremental build of the
            // test targets; not enriching costs every finding in every test file.
            if storeMissesTestTargets(packageRoot: packageRoot, store: swiftbuildStore) {
                logger.info("index store lacks test targets; building tests to enrich it")
                enrichSwiftbuildStore(packageRoot: packageRoot)
            }
            return swiftbuildStore
        }
        let managed = managedStore(packageRoot: packageRoot)
        // SAFETY: read-only existence check on a path inside the project directory
        return FileManager.default.fileExists(atPath: managed.path) ? managed : nil
    }

    /// True when the package declares tests that `store` does not cover.
    ///
    /// swiftbuild index-while-builds only what a *normal* `swift build` compiles, and that
    /// excludes test targets. The resulting store is fresh, useful, and still unable to
    /// answer a question about a test file — which is how eight of ten surviving self-call
    /// findings in a 22-package survey ended up in test suites, decided syntactically.
    ///
    /// Test modules are named by convention (`FooTests`), so their unit records carry it.
    /// A package with no `Tests` directory is never "missing" anything.
    static func storeMissesTestTargets(packageRoot: URL, store: URL) -> Bool {
        let fm = FileManager.default
        // SAFETY: read-only existence check inside the project directory
        guard fm.fileExists(atPath: packageRoot.appendingPathComponent("Tests").path) else {
            return false
        }
        // An unreadable units directory is treated as "not covered", so the enrichment is
        // retried rather than coverage being assumed that the store may not have.
        // silent: unreadable means not-covered; the caller retries rather than assuming
        guard let entries = try? fm.contentsOfDirectory(atPath: unitsDirectory(in: store).path) else {
            return true
        }
        return !entries.contains { $0.contains("Tests") }
    }

    /// Ask swiftbuild to index the test targets into its own store, in place.
    ///
    /// Deliberately *not* the dedicated `--build-system native` index build: that is a
    /// second full compile of the module graph, which is the cost fast path A exists to
    /// avoid. This is the ordinary build the developer would run anyway, with tests added,
    /// so an already-built package pays seconds rather than minutes.
    ///
    /// Best-effort. A package whose tests do not compile keeps the store it had; losing a
    /// working source index because a test target is broken would be a bad trade.
    private static func enrichSwiftbuildStore(packageRoot: URL) {
        // Enrichment is opportunistic: any failure leaves the existing store in place,
        // which is exactly the previous behaviour.
        // silent: opportunistic enrichment; failure keeps the store that already worked
        _ = try? ProcessRunner.run(
            "/usr/bin/env",
            arguments: ["swift", "build", "--build-tests", "--package-path", packageRoot.path],
            mergeStderr: true
        )
    }

    /// Ensure a fresh index store exists for `packageRoot`.
    ///
    /// Concurrent callers — e.g. two `quality-gate` runs in the same checkout — are
    /// serialized by an exclusive advisory file lock so that at most one `swift build`
    /// writes the index store at a time. Without this, two builds race to write the same
    /// store and a reader (or the builds themselves) can observe an empty/partial index —
    /// the flake that intermittently broke the cross-module index checkers.
    public static func ensureFresh(packageRoot: URL) throws -> URL {
        // Fast path A — reuse swiftbuild's own index store. Swift 6.4+ SwiftPM (the
        // `swiftbuild`/XCBuild default) index-while-builds a queryable store to
        // `.build/out/v5` during the *normal* build, so when that store exists and is
        // current there is nothing to do: we skip the dedicated index compile entirely
        // (which would otherwise be a full second build of the whole module graph — the
        // double-compile that dominated gate wall-time). Native toolchains (< 6.4) do NOT
        // index without `-index-store-path`, so `.build/out` is absent there and we fall
        // through to the dedicated, locked index build below.
        if let swiftbuildStore = freshSwiftbuildStore(packageRoot: packageRoot) {
            return swiftbuildStore
        }

        let buildPath = indexBuildDirectory(packageRoot: packageRoot)
        let store = managedStore(packageRoot: packageRoot)

        // Fast path: already fresh, no lock needed.
        guard needsRebuild(packageRoot: packageRoot, store: store) else { return store }

        // --no-index-build: a compile would be required here (no swiftbuild store, no fresh
        // dedicated store), but the caller forbade building — e.g. a portfolio sweep that must
        // not rebuild every project. Signal "unavailable"; index checkers degrade to AST-only.
        if ProcessInfo.processInfo.environment["QG_NO_INDEX_BUILD"] == "1" {
            throw Error.indexBuildSkipped
        }

        // SAFETY: CLI tool creates its local index-build directory to host the lock file
        try FileManager.default.createDirectory(at: buildPath, withIntermediateDirectories: true)
        let lockURL = buildPath.appendingPathComponent(".index-build.lock")

        try withExclusiveLock(at: lockURL) {
            // Double-checked under the lock: a peer that held the lock first may have just
            // produced a fresh store, in which case this caller skips a redundant, racy build.
            if needsRebuild(packageRoot: packageRoot, store: store) {
                try build(packageRoot: packageRoot, buildPath: buildPath, store: store)
            }
        }
        return store
    }

    /// Runs `body` while holding an exclusive, blocking advisory lock on `lockURL`.
    ///
    /// Uses `flock(2)`, so the lock is honored **across processes** — two `quality-gate`
    /// invocations in one checkout serialize their index builds instead of racing.
    static func withExclusiveLock(at lockURL: URL, _ body: () throws -> Void) throws {
        // SAFETY: CLI tool opens its local lock file
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw Error.buildFailed("could not open index-build lock at \(lockURL.path)")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw Error.buildFailed("could not acquire index-build lock")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try body()
    }

    // MARK: - Private helpers

    /// Returns swiftbuild's own index store (`.build/out`) when it exists and is current
    /// relative to `Sources`, else `nil`.
    ///
    /// Swift 6.4+ SwiftPM emits `.build/out/v5/{units,records}` as a side effect of a normal
    /// `swift build` — a full, queryable index store. Reusing it lets `ensureFresh` skip a
    /// redundant second compile. Returns `nil` when the store is absent (native toolchains,
    /// which do not index without `-index-store-path`) or stale (a source is newer than the
    /// store's records), so the caller falls back to the dedicated index build.
    static func freshSwiftbuildStore(packageRoot: URL) -> URL? {
        let store = packageRoot.appendingPathComponent(".build/out")
        let units = unitsDirectory(in: store)
        let fm = FileManager.default
        // Must exist and be a non-empty index-while-building store.
        // silent: an absent .build/out (native toolchains, or before the first index-while-build) is the expected no-store case, signaled to the caller by returning nil to trigger the dedicated index-build fallback.
        guard let entries = try? fm.contentsOfDirectory(atPath: units.path), !entries.isEmpty else {
            return nil
        }
        // Must be current: no source file newer than the store's unit records.
        guard let storeMtime = mtime(of: units) else { return nil }
        let sources = packageRoot.appendingPathComponent("Sources")
        if let newest = newestSwiftMtime(under: sources), newest > storeMtime {
            return nil
        }
        return store
    }

    private static func needsRebuild(packageRoot: URL, store: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.path) else { return true } // SAFETY: CLI tool checks local index store path
        guard let storeMtime = mtime(of: store) else { return true }
        let sources = packageRoot.appendingPathComponent("Sources")
        guard let newestSource = newestSwiftMtime(under: sources) else { return false }
        return newestSource > storeMtime
    }

    /// Returns the modification date of the file at `url`, or nil if unavailable.
    public static func mtime(of url: URL) -> Date? {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path) // SAFETY: CLI tool reads local file attributes
            return attrs[.modificationDate] as? Date
        } catch {
            logger.warning("Could not read file attributes for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Returns the most recent modification date among all `.swift` files under `root`.
    public static func newestSwiftMtime(under root: URL) -> Date? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root.path) else { return nil } // SAFETY: CLI tool enumerates local source directory
        var newest: Date?
        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            let p = root.appendingPathComponent(rel).path
            do {
                let attrs = try fm.attributesOfItem(atPath: p) // SAFETY: CLI tool reads local source file attributes
                if let m = attrs[.modificationDate] as? Date {
                    if newest.map({ m > $0 }) ?? true { newest = m }
                }
            } catch {
                logger.warning("Skipping unreadable file attributes for \(p, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return newest
    }

    /// The `swift build` invocation that produces an index store.
    ///
    /// Extracted so the shape can be asserted without running a compiler.
    static func buildArguments(
        packageRoot: URL,
        buildPath: URL,
        store: URL,
        includeTests: Bool
    ) -> [String] {
        var arguments = ["swift", "build"]
        // Swift 6.4's SwiftPM defaults to the `swiftbuild` (XCBuild) build system, which
        // does NOT honor `-index-store-path` — it emits no queryable index store, silently
        // breaking every cross-module index checker. Force the classic `native` system on
        // 6.4+ to restore the index. On < 6.4, `native` is already the default and the
        // `--build-system` flag may not exist, so it is omitted there. (native is
        // deprecated; follow-up: adopt swiftbuild's index mechanism before it is removed.)
        if let version = detectSwiftVersion(),
           requiresNativeBuildSystem(major: version.major, minor: version.minor) {
            arguments += ["--build-system", "native"]
        }
        // Test targets are not built by a plain `swift build`, so every symbol in a suite
        // was invisible to the index and every finding there was decided syntactically.
        // Across a 22-package survey that accounted for eight of the ten surviving
        // self-call findings — one of them a confirmed false positive the index resolves
        // correctly — and sixteen of the thirty-four unresolved notes. A test that recurses
        // without a base case hangs a run exactly as thoroughly as a tool does.
        if includeTests {
            arguments.append("--build-tests")
        }
        arguments += [
            "--package-path", packageRoot.path,
            "--build-path", buildPath.path,
            "-Xswiftc", "-index-store-path",
            "-Xswiftc", store.path,
        ]
        return arguments
    }

    private static func build(packageRoot: URL, buildPath: URL, store: URL) throws {
        // Index the tests when they compile; fall back to sources alone when they do not.
        // A package whose test target is broken must not lose its *entire* index over it —
        // that would trade partial coverage for none, which is strictly worse than the
        // behaviour this replaces.
        do {
            try runIndexBuild(packageRoot: packageRoot, buildPath: buildPath, store: store, includeTests: true)
        } catch {
            logger.info("index build with --build-tests failed; retrying without test targets")
            try runIndexBuild(packageRoot: packageRoot, buildPath: buildPath, store: store, includeTests: false)
        }
    }

    private static func runIndexBuild(
        packageRoot: URL,
        buildPath: URL,
        store: URL,
        includeTests: Bool
    ) throws {
        let arguments = buildArguments(
            packageRoot: packageRoot, buildPath: buildPath, store: store, includeTests: includeTests)
        let result = try ProcessRunner.run(
            "/usr/bin/env",
            arguments: arguments,
            mergeStderr: true
        )
        if result.exitCode != 0 {
            let isSigningOnly = !result.stdout.contains(": error:")
                && (result.stdout.contains("Code Signing subsystem")
                    || result.stdout.contains("codesign failed"))
            if !isSigningOnly {
                throw Error.buildFailed(result.stdout)
            }
        }
    }

    /// Parses `(major, minor)` from `swift --version` output, or nil if unrecognized.
    ///
    /// Handles the common shapes: `Apple Swift version 6.4 (...)`,
    /// `Swift version 6.0.1 (...)`, and dev snapshots like `6.2-dev`.
    static func parseSwiftVersion(fromVersionOutput output: String) -> (major: Int, minor: Int)? {
        guard let match = output.firstMatch(of: #/[Ss]wift version (\d+)\.(\d+)/#) else { return nil }
        guard let major = Int(match.1), let minor = Int(match.2) else { return nil }
        return (major, minor)
    }

    /// Whether `--build-system native` is required to emit an index store.
    ///
    /// Swift 6.4 changed the default build system to `swiftbuild`, which ignores
    /// `-index-store-path`. Toolchains at 6.4 or newer therefore need the classic
    /// `native` system; older toolchains default to `native` and may lack the flag.
    static func requiresNativeBuildSystem(major: Int, minor: Int) -> Bool {
        (major, minor) >= (6, 4)
    }

    /// Detects the active Swift compiler version via `swift --version`.
    private static func detectSwiftVersion() -> (major: Int, minor: Int)? {
        // SAFETY: subprocess with hardcoded `/usr/bin/env swift --version`
        do {
            let result = try ProcessRunner.run(
                "/usr/bin/env",
                arguments: ["swift", "--version"],
                mergeStderr: true
            )
            guard result.exitCode == 0 else { return nil }
            return parseSwiftVersion(fromVersionOutput: result.stdout)
        } catch {
            logger.warning("Could not probe swift version, assuming default build system: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
