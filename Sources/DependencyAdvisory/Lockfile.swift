import Foundation
import QualityGateCore
import QualityGateLogging

/// One pinned dependency, as a `Package.resolved` records it.
struct LockfilePin: Sendable, Equatable {
    /// The package identity SwiftPM assigned — lower-cased in a version 2 or 3 lockfile.
    let identity: String
    /// The repository URL, in whatever case and form the manifest that introduced it typed.
    let location: String
    /// The pinned version tag, when the pin tracks one.
    let version: String?
    /// The branch, when the pin tracks one.
    let branch: String?
    /// The pinned revision.
    let revision: String?
    /// The 1-based line of the pin's location in the lockfile, when it could be found.
    let line: Int?
}

/// A parsed `Package.resolved`.
struct Lockfile: Sendable, Equatable {
    /// The path relative to the project root, for a finding's `filePath`.
    let path: String
    /// The pins, in file order.
    let pins: [LockfilePin]

    /// Parses a lockfile in format version 1, 2 or 3, or returns `nil` when `contents` is not one.
    ///
    /// `nil` rather than an empty lockfile on purpose: a file that could not be understood has
    /// pins nobody checked, and an empty pin list would report that as nothing to check.
    static func parse(path: String, contents: String) -> Lockfile? {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: Data(contents.utf8))
        } catch {
            logger.warning("\(path, privacy: .public) is not JSON, so it was not read as a lockfile: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard case .array(let entries)? = root["pins"] ?? root["object"]?["pins"] else { return nil }

        // By `isNewline`, not by "\n": "\r\n" is one Character, so a lockfile checked out with
        // CRLF endings would otherwise be a single line and every pin would be reported on it.
        let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var searchFrom = 0
        var pins: [LockfilePin] = []
        for entry in entries {
            // `location`/`identity` in versions 2 and 3; `repositoryURL`/`package` in version 1.
            guard let location = (entry["location"] ?? entry["repositoryURL"])?.stringValue else { continue }
            let line = lineNumber(of: location, in: lines, from: searchFrom)
            if let line { searchFrom = line }
            pins.append(LockfilePin(
                identity: (entry["identity"] ?? entry["package"])?.stringValue ?? location,
                location: location,
                version: entry["state"]?["version"]?.stringValue,
                branch: entry["state"]?["branch"]?.stringValue,
                revision: entry["state"]?["revision"]?.stringValue,
                line: line))
        }
        return Lockfile(path: path, pins: pins)
    }

    /// The 1-based number of the first line at or after index `start` that holds `location` as
    /// a JSON string. Pins are searched in file order, so each search begins where the last
    /// ended and a repeated URL resolves to its own line.
    private static func lineNumber(of location: String, in lines: [Substring], from start: Int) -> Int? {
        let plain = "\"\(location)\""
        let escaped = "\"\(location.replacingOccurrences(of: "/", with: "\\/"))\""
        for index in lines.indices.dropFirst(start) where lines[index].contains(plain) || lines[index].contains(escaped) {
            return index + 1
        }
        return nil
    }

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DependencyAdvisory")
}

/// Finds the lockfiles under a project root.
enum LockfileDiscovery {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DependencyAdvisory")

    /// Directories that hold other packages' lockfiles, or copies of this one's.
    ///
    /// `.build` and `checkouts` are dependencies' own trees; `DerivedData` and `SourcePackages`
    /// are Xcode's; `.claude` holds worktree copies of the same repository, which the proposal's
    /// measurement excluded for the same reason — a second copy of a pin is not a second pin.
    static let skippedDirectories: Set<String> = [
        ".build", ".git", "checkouts", "DerivedData", "SourcePackages", ".claude", "node_modules", "Pods",
    ]

    /// The most lockfiles one run will read. A repository with more than this has a layout this
    /// walk did not anticipate, and the coverage note says how many were read.
    static let maximumLockfiles = 500

    /// The largest lockfile that will be read.
    static let maximumBytes = 8 * 1024 * 1024

    /// What the walk found.
    struct Discovery: Sendable {
        /// The lockfiles that parsed.
        var lockfiles: [Lockfile] = []
        /// Relative paths of files named `Package.resolved` that could not be read as one.
        var unreadable: [String] = []
    }

    /// Every `Package.resolved` under `root`, including Xcode's workspace copies, sorted by path.
    ///
    /// Xcode's copy under `*.xcworkspace/xcshareddata/swiftpm/` is included because it is what
    /// an Xcode build resolves against, and it can pin differently from the package's own.
    static func discover(under root: URL) -> Discovery {
        var discovery = Discovery()
        for path in lockfilePaths(under: root) {
            let url = root.appendingPathComponent(path)
            guard let contents = read(url), let lockfile = Lockfile.parse(path: path, contents: contents) else {
                discovery.unreadable.append(path)
                continue
            }
            discovery.lockfiles.append(lockfile)
        }
        return discovery
    }

    /// Relative paths of every `Package.resolved` under `root`, sorted, capped at ``maximumLockfiles``.
    static func lockfilePaths(under root: URL) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [], errorHandler: nil) else { return [] }

        let prefix = root.standardizedFileURL.path
        var found: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            if skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            guard name == "Package.resolved" else { continue }
            let path = url.standardizedFileURL.path
            found.append(path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count + 1)) : path)
            if found.count >= maximumLockfiles { break }
        }
        return found.sorted()
    }

    private static func read(_ url: URL) -> String? {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumBytes else {
                logger.warning("\(url.path, privacy: .public) is \(size, privacy: .public) bytes, over the limit for a lockfile; not read")
                return nil
            }
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.warning("\(url.path, privacy: .public) could not be read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
