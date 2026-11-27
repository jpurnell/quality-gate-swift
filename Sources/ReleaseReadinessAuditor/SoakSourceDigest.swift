import Crypto
import Foundation
import QualityGateCore
import QualityGateLogging

/// The digest that ties a soak result to the source it measured.
///
/// SHA-256 over the sorted `(path, git blob id)` pairs of the committed files that match the configured `sources`
/// globs. It is **not** the tree hash, because a release commit edits the CHANGELOG and the version, and that must not
/// make a soak stale; and it **does** include `Package.resolved`, because a dependency pin bump changes what ran.
///
/// It is taken from `HEAD`, not the working tree, so it names a commit's source. A soak run from a dirty tree would
/// otherwise carry the digest of source nobody committed: ``uncommittedChanges(repository:sources:)`` lets the sealer
/// refuse that.
public enum SoakSourceDigest {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "SoakSourceDigest")

    /// A committed file: its path and the blob id git stores its content under.
    public struct TrackedFile: Sendable, Equatable {
        /// The path relative to the repository root.
        public let path: String
        /// The git blob id (or the commit id, for a submodule).
        public let blobID: String

        /// Creates a tracked file.
        public init(path: String, blobID: String) {
            self.path = path
            self.blobID = blobID
        }
    }

    /// Does `path` match `pattern`? A pattern is `/`-separated; `**` matches one or more directories' worth of path at
    /// its position (so `Sources/**` is everything beneath `Sources`), and `*` and `?` match within one segment.
    public static func matches(_ path: String, pattern: String) -> Bool {
        match(pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)[...],
              path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)[...])
    }

    private static func match(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let head = pattern.first else { return path.isEmpty }
        if head == "**" {
            let rest = pattern.dropFirst()
            if rest.isEmpty { return !path.isEmpty }
            // The recursion is bounded by the path's depth: each step drops one segment.
            return (0..<path.count).contains { match(rest, path.dropFirst($0)) }
        }
        guard let segment = path.first, fnmatch(head, segment, 0) == 0 else { return false }
        return match(pattern.dropFirst(), path.dropFirst())
    }

    /// The digest of the files that match `sources`, or `nil` when none do: a configuration that selects nothing is a
    /// mistake to report, not a digest of nothing that every empty package shares.
    public static func digest(of files: [TrackedFile], sources: [String]) -> String? {
        let selected = files.filter { file in sources.contains { matches(file.path, pattern: $0) } }
        guard !selected.isEmpty else { return nil }
        var hasher = SHA256()
        for file in selected.sorted(by: { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }) {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(file.blobID.utf8))
            hasher.update(data: Data([10]))
        }
        return hasher.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    /// The digest of `HEAD`'s source in a repository, or `nil` if it is not a repository, git fails, or no file matches.
    public static func digest(repository: String, sources: [String]) -> String? {
        guard let output = git(["ls-tree", "-r", "-z", "HEAD"], in: repository) else { return nil }
        var files: [TrackedFile] = []
        for entry in output.split(separator: "\0", omittingEmptySubsequences: true) {
            // `<mode> <type> <blob>\t<path>`
            let halves = entry.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard halves.count == 2 else { continue }
            let fields = halves[0].split(separator: " ")
            guard fields.count == 3 else { continue }
            files.append(TrackedFile(path: String(halves[1]), blobID: String(fields[2])))
        }
        return digest(of: files, sources: sources)
    }

    /// Paths matching `sources` that differ from `HEAD`: modified, staged, deleted, renamed or untracked. A soak sealed
    /// while this is not empty would carry the digest of source that does not exist as a commit.
    ///
    /// - Returns: The paths, sorted; empty if there are none. `nil` if git could not be asked.
    public static func uncommittedChanges(repository: String, sources: [String]) -> [String]? {
        guard let output = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: repository) else { return nil }
        var paths: [String] = []
        var tokens = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let token = tokens.next() {
            guard token.count > 3 else { continue }
            paths.append(String(token.dropFirst(3)))
            // A rename or copy is followed by its origin path as a separate entry.
            if token.first == "R" || token.first == "C", let origin = tokens.next() { paths.append(String(origin)) }
        }
        return paths.filter { path in sources.contains { matches(path, pattern: $0) } }.sorted()
    }

    private static func git(_ arguments: [String], in repository: String) -> String? {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment[key] = nil }
        do {
            let result = try ProcessRunner.run(
                "/usr/bin/git", arguments: ["-C", repository] + arguments, environment: environment, timeout: 60)
            guard result.exitCode == 0 else {
                logger.debug("git \(arguments.first ?? "", privacy: .public) exited \(result.exitCode, privacy: .public)")
                return nil
            }
            return result.stdout
        } catch {
            logger.debug("git could not run: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
