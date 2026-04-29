import Foundation

/// Ensures the SwiftPM index store at `<root>/.build/index-store` is fresh.
///
/// Compares the modification time of the newest `.swift` file under
/// `Sources/` to the modification time of the index store directory.
/// Rebuilds via `swift build -Xswiftc -index-store-path -Xswiftc <store>`
/// if the store is missing or stale. Build failures throw — the caller
/// is expected to downgrade them to a `.note` diagnostic so the gate
/// never fails purely on build inability.
enum IndexStoreManager {

    enum Error: LocalizedError {
        case buildFailed(String)
        var errorDescription: String? {
            switch self {
            case .buildFailed(let s):
                return "swift build (index-store) failed: \(s)"
            }
        }
    }

    /// A located index store, plus whether we believe it is stale relative
    /// to the current source tree.
    struct LocatedStore {
        var url: URL
        var isStale: Bool
    }

    /// Locate an index store appropriate to a `ProjectKind`. SwiftPM packages
    /// are auto-built (always fresh); Xcode projects use the existing
    /// DerivedData entry; plain directories return `nil`.
    static func locate(projectKind: ProjectKind) throws -> LocatedStore? {
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

    /// Shared lookup for both `.xcode` and `.xcworkspace`. The DerivedData
    /// entry name is derived from the basename of the project / workspace
    /// file.
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

    // MARK: - Auto-build (Component 4)

    /// Parse the JSON output of `xcodebuild -list -json` and return the
    /// first scheme. Throws if the JSON is malformed or has no schemes.
    static func firstScheme(fromXcodebuildListJSON data: Data) throws -> String {
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

    /// Configuration knobs for the optional Xcode auto-build path.
    struct XcodebuildOptions: Sendable {
        var scheme: String?       // nil ⇒ auto-pick the first scheme
        var destination: String   // default "generic/platform=macOS"
        var configuration: String // default "Debug"
        var derivedDataPath: URL  // default <root>/.build/xcode-derived

        static func defaults(rootURL: URL) -> XcodebuildOptions {
            XcodebuildOptions(
                scheme: nil,
                destination: "generic/platform=macOS",
                configuration: "Debug",
                derivedDataPath: rootURL.appendingPathComponent(".build/xcode-derived")
            )
        }
    }

    /// Drive `xcodebuild build` to produce a fresh index store.
    ///
    /// Returns the index store URL on success, or throws on failure (the
    /// caller is expected to downgrade the failure to a `.note`).
    static func runXcodebuild(
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

        // Build the project, isolating into our own derived-data path.
        let proc = Process() // SAFETY: runs xcodebuild to produce an index store for dead-code analysis
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "xcodebuild", "build",
            flag, file.path,
            "-scheme", scheme,
            "-configuration", options.configuration,
            "-destination", options.destination,
            "-derivedDataPath", options.derivedDataPath.path,
            "COMPILER_INDEX_STORE_ENABLE=YES",
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let tail = (String(data: data, encoding: .utf8) ?? "").suffix(2000)
            throw Error.buildFailed("xcodebuild build exited \(proc.terminationStatus): \(tail)")
        }

        let store = options.derivedDataPath.appendingPathComponent("Index.noindex/DataStore")
        guard FileManager.default.fileExists(atPath: store.path) else { // SAFETY: CLI tool checks local index store path
            throw Error.buildFailed("xcodebuild succeeded but no index store at \(store.path)")
        }
        return store
    }

    private static func listFirstScheme(flag: String, filePath: URL) throws -> String {
        let proc = Process() // SAFETY: runs xcodebuild -list to discover available schemes
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["xcodebuild", "-list", "-json", flag, filePath.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()  // discard
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if proc.terminationStatus != 0 {
            throw Error.buildFailed("xcodebuild -list exited \(proc.terminationStatus)")
        }
        return try firstScheme(fromXcodebuildListJSON: data)
    }

    /// Find a usable Xcode-emitted index store under `derivedDataRoot`.
    ///
    /// DerivedData entries look like `<SanitizedName>-<hash>/`. Spaces in
    /// `projectName` are converted to underscores (Xcode's convention).
    /// When multiple entries match, the newest by `Index.noindex/DataStore`
    /// mtime wins. If `info.plist` is present its `WorkspacePath` must
    /// resolve to `projectPath` (best-effort filter).
    ///
    /// `derivedDataRoot` is injected so tests can plant fake entries
    /// without touching `~/Library/Developer/Xcode/DerivedData`.
    static func locateInDerivedData(
        projectName: String,
        projectPath: URL,
        derivedDataRoot: URL
    ) -> URL? {
        let fm = FileManager.default
        let sanitized = projectName.replacingOccurrences(of: " ", with: "_")
        guard let entries = try? fm.contentsOfDirectory(atPath: derivedDataRoot.path) else { // SAFETY: CLI tool enumerates local DerivedData
            return nil
        }
        var matches: [(URL, Date)] = []
        for entry in entries {
            // Strip the trailing `-<hash>` to get the sanitized project name.
            guard let dash = entry.lastIndex(of: "-") else { continue }
            let prefix = String(entry[..<dash])
            guard prefix == sanitized else { continue }

            let entryDir = derivedDataRoot.appendingPathComponent(entry)
            let store = entryDir.appendingPathComponent("Index.noindex/DataStore")
            guard fm.fileExists(atPath: store.path) else { continue } // SAFETY: CLI tool checks local index store path

            // Best-effort workspace-path validation.
            let infoPlist = entryDir.appendingPathComponent("info.plist")
            if let data = try? Data(contentsOf: infoPlist),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let dict = plist as? [String: Any],
               let ws = dict["WorkspacePath"] as? String {
                let canonicalWS = URL(fileURLWithPath: ws).resolvingSymlinksInPath().path
                let canonicalProj = projectPath.resolvingSymlinksInPath().path
                if canonicalWS != canonicalProj { continue }
            }

            let mtime = (try? fm.attributesOfItem(atPath: store.path)[.modificationDate] as? Date) ?? .distantPast // SAFETY: CLI tool reads local file attributes
            matches.append((store, mtime))
        }
        return matches.max(by: { $0.1 < $1.1 })?.0
    }

    /// Conservative staleness check: store is stale if any `.swift` file
    /// under `sourcesRoot` is newer than the store directory.
    static func isIndexStoreStale(store: URL, sourcesRoot: URL) -> Bool {
        guard let storeMtime = mtime(of: store) else { return true }
        guard let newest = newestSwiftMtime(under: sourcesRoot) else { return false }
        return newest > storeMtime
    }

    static func defaultDerivedDataRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    /// Ensure a fresh index store exists for `packageRoot`.
    ///
    /// Uses an isolated build path (`.build/index-build`) so SwiftPM's
    /// incremental build cache for the indexed build is independent of
    /// any normal `.build` state — a fresh `swift build` against a warm
    /// `.build` would otherwise skip compilation and never re-emit index
    /// units.
    ///
    /// - Parameter packageRoot: Absolute URL of a SwiftPM package root.
    /// - Returns: Absolute URL of the index store directory.
    /// - Throws: `Error.buildFailed` if `swift build` exits non-zero.
    static func ensureFresh(packageRoot: URL) throws -> URL {
        let buildPath = packageRoot.appendingPathComponent(".build/index-build")
        let store = buildPath.appendingPathComponent("index-store")
        if needsRebuild(packageRoot: packageRoot, store: store) {
            try build(packageRoot: packageRoot, buildPath: buildPath, store: store)
        }
        return store
    }

    // MARK: - Private

    private static func needsRebuild(packageRoot: URL, store: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.path) else { return true } // SAFETY: CLI tool checks local index store path
        guard let storeMtime = mtime(of: store) else { return true }
        let sources = packageRoot.appendingPathComponent("Sources")
        guard let newestSource = newestSwiftMtime(under: sources) else { return false }
        return newestSource > storeMtime
    }

    static func mtime(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) // SAFETY: CLI tool reads local file attributes
        return attrs?[.modificationDate] as? Date
    }

    static func newestSwiftMtime(under root: URL) -> Date? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root.path) else { return nil }
        var newest: Date?
        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            let p = root.appendingPathComponent(rel).path
            if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date { // SAFETY: CLI tool reads local file attributes
                if newest.map({ m > $0 }) ?? true { newest = m }
            }
        }
        return newest
    }

    private static func build(packageRoot: URL, buildPath: URL, store: URL) throws {
        let proc = Process() // SAFETY: runs swift build with index-store flags for dead-code analysis
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "swift", "build",
            "--package-path", packageRoot.path,
            "--build-path", buildPath.path,
            "-Xswiftc", "-index-store-path",
            "-Xswiftc", store.path,
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            throw Error.buildFailed(String(data: data, encoding: .utf8) ?? "")
        }
    }
}
