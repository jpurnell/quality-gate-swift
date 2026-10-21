import Foundation
import QualityGateLogging

/// Walks a directory tree in sorted pre-order, reading each directory as it is entered.
///
/// ## Why this exists instead of `FileManager.enumerator`
///
/// On Linux, swift-corelibs-foundation builds its directory enumerator on glibc `fts`, opened
/// with `FTS_PHYSICAL | FTS_NOSTAT`. Under `FTS_NOSTAT`, `fts` takes a directory's link count
/// when the walk opens it and stats only that many subdirectories, assuming the rest are files.
/// A directory created after the walk opens uses up the count, and a real subdirectory is then
/// yielded but never entered. No error is raised and the error handler is never called.
///
/// The gate creates `.build/quality-gate-cache` part-way through every run, while other checkers
/// are walking the same root. A checker that had opened its walk first lost `Sources/` and
/// reported a clean pass over a project it never read: on Swift 6.4, 39 of 50 walks in CI
/// (macOS, whose Foundation does not use `fts`, 0 of 50). `contentsOfDirectory(at:)` on Linux is
/// the same enumerator with one level, so it is no way round.
///
/// This type lists each directory with `contentsOfDirectory(atPath:)` — `readdir` on Linux, in
/// swift-foundation, not `fts` — and classifies every entry with `lstat`, so nothing is inferred
/// from a count taken earlier. A directory created mid-walk is
/// either listed or not, depending on timing, but it can never cost the walk an existing one.
///
/// ## Behaviour
///
/// - Symbolic links are yielded, never followed, as `FileManager`'s enumerator does.
/// - Siblings are yielded in sorted order, so two walks of one tree agree.
/// - A directory that cannot be opened is recorded in ``unreadableDirectories`` and logged,
///   rather than vanishing: findings under it are unknown, not absent.
public final class FileTreeWalker: Sequence, IteratorProtocol {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "FileTreeWalker")

    /// What to leave out of the walk.
    public struct Options: OptionSet, Sendable {
        /// The raw bit set.
        public let rawValue: Int

        /// Creates options from a raw bit set.
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Skip entries whose name starts with `.`, and everything beneath such a directory.
        public static let skipsHiddenFiles = Options(rawValue: 1 << 0)
    }

    /// One file, directory or link the walk found.
    public struct Entry: Sendable, Equatable {
        /// What kind of filesystem object an entry is, as `lstat` reports it.
        public enum Kind: Sendable, Equatable {
            /// A directory. The walk enters it unless told to skip it.
            case directory
            /// A regular file.
            case regularFile
            /// A symbolic link, whatever it points to. The walk does not follow it.
            case symbolicLink
            /// Anything else: a socket, FIFO or device node.
            case other
        }

        /// Path from the walk's root, with `/` separators and no leading slash.
        public let relativePath: String
        /// The root joined with ``relativePath``.
        public let path: String
        /// The entry's kind.
        public let kind: Kind
        /// Depth below the root: `1` for the root's own children.
        public let level: Int

        /// The entry's location as a file URL.
        public var url: URL { URL(fileURLWithPath: path, isDirectory: kind == .directory) }
        /// The last path component.
        public var name: String { (relativePath as NSString).lastPathComponent }
        /// Whether the entry is a directory (a link to one is not).
        public var isDirectory: Bool { kind == .directory }
        /// Whether the entry is a regular file.
        public var isRegularFile: Bool { kind == .regularFile }
        /// Whether the entry is a symbolic link.
        public var isSymbolicLink: Bool { kind == .symbolicLink }
    }

    /// The directory the walk started from, as given.
    public let root: String
    /// What the walk leaves out.
    public let options: Options
    /// Directories the walk could not open, as absolute paths, in the order it met them.
    public private(set) var unreadableDirectories: [String] = []
    /// Depth of the entry most recently returned by ``next()``; `0` before the first.
    public private(set) var level = 0

    /// Sibling lists still to visit, innermost last; each list is reversed so `popLast` is next.
    private var pending: [[Entry]] = []
    /// The directory most recently returned, to be entered on the next call unless skipped.
    private var toEnter: Entry?
    private var started = false

    /// Creates a walk of the tree under `root`. Nothing is read until the first ``next()``.
    ///
    /// - Parameters:
    ///   - root: The directory to walk. Its own entry is not yielded.
    ///   - options: What to leave out.
    public init(root: String, options: Options = []) {
        self.root = root
        self.options = options
    }

    /// Creates a walk of the tree under a file URL.
    ///
    /// - Parameters:
    ///   - root: The directory to walk. Its own entry is not yielded.
    ///   - options: What to leave out.
    public convenience init(root: URL, options: Options = []) {
        self.init(root: root.path, options: options)
    }

    /// Stops the walk entering the directory most recently returned by ``next()``.
    ///
    /// Has no effect when that entry was not a directory.
    public func skipDescendants() {
        toEnter = nil
    }

    /// Returns the next entry in sorted pre-order, or `nil` when the walk is done.
    public func next() -> Entry? {
        if !started {
            started = true
            push(children(ofDirectory: root, relativePath: "", level: 1))
        }
        if let directory = toEnter {
            toEnter = nil
            push(children(ofDirectory: directory.path, relativePath: directory.relativePath, level: directory.level + 1))
        }
        while var siblings = pending.popLast() {
            guard let entry = siblings.popLast() else { continue }
            if !siblings.isEmpty { pending.append(siblings) }
            if entry.isDirectory { toEnter = entry }
            level = entry.level
            return entry
        }
        return nil
    }

    private func push(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        pending.append(entries.reversed())
    }

    /// Lists one directory, sorted, classifying each entry with `lstat`.
    private func children(ofDirectory directory: String, relativePath: String, level: Int) -> [Entry] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch {
            unreadableDirectories.append(directory)
            Self.logger.warning(
                "could not open \(directory, privacy: .public) — files beneath it were not walked, so findings there are unknown, not absent: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let skipHidden = options.contains(.skipsHiddenFiles)
        return names
            .filter { !(skipHidden && $0.hasPrefix(".")) }
            .sorted()
            .compactMap { name in
                let path = (directory as NSString).appendingPathComponent(name)
                guard let kind = Self.kind(atPath: path) else { return nil }
                let relative = relativePath.isEmpty ? name : relativePath + "/" + name
                return Entry(relativePath: relative, path: path, kind: kind, level: level)
            }
    }

    /// The kind of the object at `path`, without following a final symbolic link, or `nil` when
    /// it was removed between the listing and the `lstat`.
    private static func kind(atPath path: String) -> Entry.Kind? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            logger.debug("\(path, privacy: .public) vanished during the walk: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory?: return .directory
        case .typeRegular?: return .regularFile
        case .typeSymbolicLink?: return .symbolicLink
        default: return .other
        }
    }
}
