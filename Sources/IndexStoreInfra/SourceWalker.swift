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

    /// What a walk covered, and what it left out.
    ///
    /// A checker's silence has been over-read twice in a single day. `process-safety` passed for
    /// months while six deadlocks sat in directories its walk was never pointed at, and the
    /// git-ignore change read as inert because the file count happened to stay at 640 — two
    /// unrelated changes cancelling exactly. Both times the scope was known and thrown away.
    ///
    /// So exclusions are returned alongside the files, and checkers that emit a coverage note
    /// state them. A run that read less than the whole tree should say how much less.
    public struct WalkResult: Sendable {
        /// Absolute paths of the `.swift` files the walk hands to a checker.
        public let files: [String]
        /// `.swift` files skipped because they matched `excludePatterns` from configuration.
        public let excludedByPattern: Int
        /// `.swift` files skipped because git ignores them individually.
        public let excludedByGitIgnore: Int
        /// Whole directories skipped because git ignores them.
        ///
        /// Counted as directories rather than as the files within, deliberately: descending into
        /// an ignored tree purely to count it would mean enumerating `.build`, the largest thing
        /// on disk and the very reason the skip exists. A coarse honest number beats an expensive
        /// or invented precise one.
        public let gitIgnoredDirectories: Int
        /// Directories skipped because they carry their own `Package.swift`.
        ///
        /// A nested manifest means a *different* package — its own targets, its own rules,
        /// neither built nor released by this one. Auditing it reports our house rules against
        /// someone else's code, which is the incoherence the git-ignore rule above exists to
        /// prevent, arriving by a route `.gitignore` cannot describe: a checked-in prototype
        /// or a sibling package is tracked, not ignored.
        ///
        /// Counted as directories for the same reason as `gitIgnoredDirectories`: the walk
        /// stops at the boundary rather than descending to count what it has just declined.
        public let nestedPackageDirectories: Int

        /// The scope clause for a coverage note, or `nil` when the walk read everything it found.
        ///
        /// Absent rather than "0 excluded" so the ordinary case stays quiet: a clause printed on
        /// every run stops being read, and this one needs to be read on the runs where it appears.
        public var exclusionClause: String? {
            var parts: [String] = []
            if excludedByPattern > 0 { parts.append("\(excludedByPattern) excluded by config") }
            if excludedByGitIgnore > 0 { parts.append("\(excludedByGitIgnore) git-ignored") }
            if gitIgnoredDirectories > 0 {
                let noun = gitIgnoredDirectories == 1 ? "directory" : "directories"
                parts.append("\(gitIgnoredDirectories) git-ignored \(noun)")
            }
            if nestedPackageDirectories > 0 {
                let noun = nestedPackageDirectories == 1 ? "package" : "packages"
                parts.append("\(nestedPackageDirectories) nested \(noun)")
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    /// Returns absolute paths of every `.swift` file under `root`,
    /// skipping the default-skip set, `*.xcodeproj` / `*.xcworkspace`
    /// containers, and anything matching `excludePatterns`.
    ///
    /// A thin wrapper over ``walk(under:excludePatterns:)``, kept so the existing call sites are
    /// untouched by the addition of exclusion reporting.
    public static func swiftFiles(under root: URL, excludePatterns: [String] = []) -> [String] {
        walk(under: root, excludePatterns: excludePatterns).files
    }

    /// Walks `root`, returning the `.swift` files found *and* an account of what was left out.
    public static func walk(under root: URL, excludePatterns: [String] = []) -> WalkResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return WalkResult(
                files: [], excludedByPattern: 0, excludedByGitIgnore: 0,
                gitIgnoredDirectories: 0, nestedPackageDirectories: 0)
        }

        let ignored = gitIgnoredPaths(under: root)
        var out: [String] = []
        var byPattern = 0
        var byIgnoreFile = 0
        var ignoredDirectories = 0
        var nestedPackages = 0

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
                // The default skip list is tested *first*, and the order is load-bearing for the
                // reported number. `.build` and `.swiftpm` are both default-skipped and
                // git-ignored; charging them to git-ignore would give every repository a large
                // count dominated by build output, saying nothing about the scope decision this
                // reporting exists to expose — and a number nobody reads is worse than none.
                if defaultSkipDirectories.contains(name)
                    || name.hasSuffix(".xcodeproj")
                    || name.hasSuffix(".xcworkspace") {
                    enumerator.skipDescendants()
                } else if ignored.contains(url.standardizedFileURL.path) {
                    ignoredDirectories += 1
                    enumerator.skipDescendants()
                } else if fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                    // A different package. Only reachable for a *nested* directory — the
                    // enumerator never yields `root` itself, so a package's own manifest can
                    // never make it walk itself away and report a clean pass over zero files.
                    nestedPackages += 1
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            let path = url.path
            if shouldExclude(path: path, patterns: excludePatterns) {
                byPattern += 1
                continue
            }
            if ignored.contains(url.standardizedFileURL.path) {
                byIgnoreFile += 1
                continue
            }
            out.append(path)
        }
        return WalkResult(
            files: out,
            excludedByPattern: byPattern,
            excludedByGitIgnore: byIgnoreFile,
            gitIgnoredDirectories: ignoredDirectories,
            nestedPackageDirectories: nestedPackages)
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
        // A non-repository yielding no exclusions is documented above and correct. git
        // *failing inside a repository* takes the identical path and is not: the walk then
        // includes everything .gitignore names — `.build/checkouts` above all — so findings
        // from third-party dependency source are attributed to this project. The 30s
        // timeout makes that reachable on a large tree, not hypothetical.
        let result: ProcessRunner.Output
        do {
            result = try ProcessRunner.run(
                "/usr/bin/git",
                arguments: ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"],
                currentDirectory: root.path,
                timeout: 30)
        } catch {
            Self.logger.warning(
                "source walk could not ask git for ignored paths under \(root.path, privacy: .public); scanning without exclusions, which may surface findings from ignored directories: \(error.localizedDescription, privacy: .public)")
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
