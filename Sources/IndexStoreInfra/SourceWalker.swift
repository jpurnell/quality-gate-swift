import Foundation
import QualityGateCore
#if canImport(os)
import os
#endif

/// Recursively enumerates `.swift` files under a project root, skipping
/// build outputs, dependency directories, and Xcode container packages.
public enum SourceWalker {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "SourceWalker")

    static let defaultSkipDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", ".bundle",
        "DerivedData", "build", "Build", "Pods", "Carthage", "node_modules",
    ]

    /// Returns absolute paths of every `.swift` file under `root`,
    /// skipping the default-skip set, `*.xcodeproj` / `*.xcworkspace`
    /// containers, and anything matching `excludePatterns`.
    public static func swiftFiles(under root: URL, excludePatterns: [String] = []) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return [] }

        let ignored = gitIgnoredPaths(under: root)
        var out: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDirectory: Bool
            do {
                isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            } catch {
                logger.warning("Could not read resource values for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                isDirectory = false
            }
            if isDirectory {
                if defaultSkipDirectories.contains(name)
                    || name.hasSuffix(".xcodeproj")
                    || name.hasSuffix(".xcworkspace")
                    || ignored.contains(url.standardizedFileURL.path) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            let path = url.path
            if shouldExclude(path: path, patterns: excludePatterns) { continue }
            if ignored.contains(url.standardizedFileURL.path) { continue }
            out.append(path)
        }
        return out
    }

    /// Absolute paths git has been told to ignore under `root`.
    ///
    /// ## Why the walk needs this at all
    ///
    /// The enumeration above reads the filesystem, so it has always audited whatever happened to
    /// sit on disk — including vendored trees this repository does not own and cannot fix. That
    /// is incoherent for a `convention`-kind checker, which reports a house rule: a vendored
    /// dependency never agreed to it. It found a real deadlock in a vendored script once, and
    /// that bug was fixed at its source, which is where such fixes have to go anyway.
    ///
    /// ## Ignored, deliberately not untracked
    ///
    /// The two are one flag apart and conflating them would be far worse than the problem being
    /// solved. A `.swift` file written a minute ago and not yet staged is **untracked and
    /// entirely ours**. Were the walk to skip untracked files, the gate's verdict would depend on
    /// what had been staged rather than on the code: add a checker, watch the gate pass, then
    /// turn it red by running `git add`. Ignored is the honest signal, because it is someone
    /// deliberately declaring a path outside the repository.
    ///
    /// A directory that is not a git repository yields nothing here and is walked in full —
    /// foreign-mode surveys point at strangers' packages, and silently reducing a survey to zero
    /// files while reporting success is precisely the failure this walk must not have.
    private static func gitIgnoredPaths(under root: URL) -> Set<String> {
        // silent: no git, no exclusion — a non-repository is walked in full, exactly as before.
        guard let result = try? ProcessRunner.run(
            "/usr/bin/git",
            arguments: ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"],
            currentDirectory: root.path,
            timeout: 30
        ) else {
            return []
        }
        guard result.exitCode == 0 else { return [] }

        let base = root.standardizedFileURL
        var paths: Set<String> = []
        // `.lines`, not `split(separator: "\n")`: CRLF is a single Swift `Character`, so splitting
        // on a newline literal returns a whole CRLF document as one element and the ignore set
        // ends up holding a single nonsense path. Caught by the gate's own newline-split rule on
        // the first run of this function.
        for line in result.stdout.lines {
            let relative = line.trimmingCharacters(in: .whitespaces)
            guard !relative.isEmpty else { continue }
            // `--directory` collapses a wholly-ignored directory to a single trailing-slash entry.
            let trimmed = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
            paths.insert(base.appendingPathComponent(trimmed).standardizedFileURL.path)
        }
        return paths
    }

    private static func shouldExclude(path: String, patterns: [String]) -> Bool {
        isExcluded(path: path, patterns: patterns)
    }

    /// Whether `path` matches any of `patterns` under the walker's substring rule.
    ///
    /// Glob markers (`**/`, `/**`, `*`) are stripped and the remainder is matched
    /// as a substring of `path`. Shared so index-backed passes filter emitted
    /// diagnostics with exactly the same semantics the file walk uses to skip files.
    ///
    /// - Parameters:
    ///   - path: An absolute file path to test.
    ///   - patterns: Exclude / vendor patterns (empty never matches).
    /// - Returns: `true` when any non-empty stripped pattern is a substring of `path`.
    public static func isExcluded(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            let stripped = pattern
                .replacingOccurrences(of: "**/", with: "")
                .replacingOccurrences(of: "/**", with: "")
                .replacingOccurrences(of: "*", with: "")
            if !stripped.isEmpty, path.contains(stripped) { return true }
        }
        return false
    }
}
