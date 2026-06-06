import Foundation
import os
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
    public static func ensureFresh(packageRoot: URL) throws -> URL {
        let buildPath = packageRoot.appendingPathComponent(".build/index-build")
        let store = buildPath.appendingPathComponent("index-store")
        if needsRebuild(packageRoot: packageRoot, store: store) {
            try build(packageRoot: packageRoot, buildPath: buildPath, store: store)
        }
        return store
    }

    // MARK: - Private helpers

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
        let result = try ProcessRunner.run(
            "/usr/bin/env",
            arguments: [
                "swift", "build",
                "--package-path", packageRoot.path,
                "--build-path", buildPath.path,
                "-Xswiftc", "-index-store-path",
                "-Xswiftc", store.path,
            ],
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
}
