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
        /// A human-readable description of the build failure.
        public var errorDescription: String? {
            switch self {
            case .buildFailed(let s):
                return "swift build (index-store) failed: \(s)"
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

        /// Creates a located store with the given URL and staleness flag.
        public init(url: URL, isStale: Bool) {
            self.url = url
            self.isStale = isStale
        }
    }

    /// Locate an index store appropriate to a `ProjectKind`.
    public static func locate(projectKind: ProjectKind) throws -> LocatedStore? {
        switch projectKind {
        case .swiftPM(let packageRoot):
            let url = try ensureFresh(packageRoot: packageRoot)
            return LocatedStore(url: url, isStale: false)

        case .xcode(let projectFile, let root):
            return locateXcode(file: projectFile, root: root)

        case .xcworkspace(let workspaceFile, let root):
            return locateXcode(file: workspaceFile, root: root)

        case .plain:
            return nil
        }
    }

    private static func locateXcode(file: URL, root: URL) -> LocatedStore? {
        let name = file.deletingPathExtension().lastPathComponent
        guard let url = locateInDerivedData(
            projectName: name,
            projectPath: file,
            derivedDataRoot: defaultDerivedDataRoot()
        ) else { return nil }
        let isStale = isIndexStoreStale(store: url, sourcesRoot: root)
        return LocatedStore(url: url, isStale: isStale)
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

        let buildPath = packageRoot.appendingPathComponent(".build/index-build")
        let store = buildPath.appendingPathComponent("index-store")

        // Fast path: already fresh, no lock needed.
        guard needsRebuild(packageRoot: packageRoot, store: store) else { return store }

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
        let units = store.appendingPathComponent("v5/units")
        let fm = FileManager.default
        // Must exist and be a non-empty index-while-building store.
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

    private static func build(packageRoot: URL, buildPath: URL, store: URL) throws {
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
        arguments += [
            "--package-path", packageRoot.path,
            "--build-path", buildPath.path,
            "-Xswiftc", "-index-store-path",
            "-Xswiftc", store.path,
        ]
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
