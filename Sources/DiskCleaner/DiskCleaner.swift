import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// What a cleanup run removed.
public struct CleanupSummary: Sendable, Equatable {
    /// Total bytes reclaimed across every artifact removed.
    public let totalBytesFreed: Int64
    /// Human-readable lines describing what was removed — or would be, when previewing.
    public let messages: [String]
    /// Non-fatal problems encountered (e.g. `git gc` failing).
    public let warnings: [String]
    /// Whether the run only previewed the work instead of performing it.
    public let wasDryRun: Bool

    /// Creates a summary.
    public init(totalBytesFreed: Int64, messages: [String], warnings: [String], wasDryRun: Bool) {
        self.totalBytesFreed = totalBytesFreed
        self.messages = messages
        self.warnings = warnings
        self.wasDryRun = wasDryRun
    }
}

/// Removes build artifacts and optionally compacts git history.
///
/// Removes `.build/` (SwiftPM artifacts) and any `.docc-build/` directories, and can run
/// `git gc` to compress history.
///
/// ## Deliberately not a `QualityChecker`
///
/// Checkers observe and report; this mutates the tree — and it deletes the very `.build/`
/// directory, index store included, that nine index-backed auditors read. While it wore
/// the checker protocol it once produced a fabricated 61-error run by wiping the tree its
/// peers depended on. Safety then rested on a hardcoded denylist that any future
/// destructive checker would have had to remember to join; keeping mutation off the
/// protocol makes the separation structural instead of remembered.
///
/// Reached via `quality-gate clean`.
///
/// ## Usage
///
/// ```swift
/// let summary = DiskCleaner().clean(dryRun: false, runGitGC: true)
/// print(summary.totalBytesFreed)
/// ```
public struct DiskCleaner: Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "DiskCleaner")

    /// Creates a new DiskCleaner instance.
    public init() {}

    /// Whether an invocation asked for a preview rather than a deletion.
    ///
    /// `--dry-run` is declared on the *root* `quality-gate` command, and ArgumentParser
    /// resolves parent options before the subcommand's own — so a `--dry-run` flag
    /// declared on `clean` is silently shadowed and never set. That failure mode is
    /// catastrophic here: the user types the word "dry-run" and watches the build tree
    /// disappear. It happened once during development, costing a 20 GB rebuild.
    ///
    /// So the preview flag is spelled `--preview`, and `--dry-run` is honored by
    /// inspecting the raw arguments. Both spellings preview; neither deletes.
    ///
    /// - Parameters:
    ///   - previewFlag: The parsed `--preview` flag.
    ///   - arguments: The raw process arguments.
    /// - Returns: `true` when the run must not delete anything.
    public static func wantsPreview(previewFlag: Bool, arguments: [String]) -> Bool {
        previewFlag || arguments.contains("--dry-run")
    }

    /// Removes build artifacts under the current directory.
    ///
    /// - Parameters:
    ///   - dryRun: When `true`, reports what would be removed and deletes nothing.
    ///   - runGitGC: When `true`, also runs `git gc --aggressive --prune=now` in a git
    ///     repository. Never runs during a dry run — gc rewrites the object store, which
    ///     is precisely what a preview must not do.
    /// - Returns: A summary of what was, or would be, reclaimed.
    public func clean(dryRun: Bool = false, runGitGC gcRequested: Bool = false) -> CleanupSummary {
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath

        var messages: [String] = []
        var warnings: [String] = []
        var totalBytesFreed: Int64 = 0

        // Clean .build directory
        let buildPath = (currentDir as NSString).appendingPathComponent(".build")
        if let freed = cleanDirectory(at: buildPath, dryRun: dryRun) {
            totalBytesFreed += freed
            messages.append("\(dryRun ? "Would remove" : "Removed") .build/ (\(formatBytes(freed)))")
        }

        // Find and clean .docc-build directories recursively
        let doccBuildPaths = findDirectories(named: ".docc-build", in: currentDir)
        for doccPath in doccBuildPaths {
            if let freed = cleanDirectory(at: doccPath, dryRun: dryRun) {
                totalBytesFreed += freed
                let relativePath = doccPath.replacingOccurrences(of: currentDir + "/", with: "")
                messages.append("\(dryRun ? "Would remove" : "Removed") \(relativePath) (\(formatBytes(freed)))")
            }
        }

        // Run git gc only when asked, and never while previewing.
        let gitPath = (currentDir as NSString).appendingPathComponent(".git")
        if gcRequested, !dryRun, fileManager.fileExists(atPath: gitPath) { // SAFETY: checks .git in CLI working directory
            let gitSizeBefore = directorySize(at: gitPath)

            let gcResult = runGitGC()
            if gcResult.success {
                let gitSizeAfter = directorySize(at: gitPath)
                let freed = gitSizeBefore - gitSizeAfter
                if freed > 0 {
                    totalBytesFreed += freed
                    messages.append("Git gc freed \(formatBytes(freed))")
                }
            } else if let error = gcResult.error {
                warnings.append("Git gc failed: \(error)")
            }
        }

        if totalBytesFreed > 0 {
            messages.insert(
                "Total disk space \(dryRun ? "recoverable" : "freed"): \(formatBytes(totalBytesFreed))",
                at: 0)
        } else {
            messages.append("No build artifacts to clean")
        }

        return CleanupSummary(
            totalBytesFreed: totalBytesFreed,
            messages: messages,
            warnings: warnings,
            wasDryRun: dryRun)
    }

    // MARK: - Private Implementation

    /// Measures `path`, and removes it unless this is a dry run.
    ///
    /// - Returns: The bytes reclaimed (or reclaimable), or `nil` when nothing is there.
    private func cleanDirectory(at path: String, dryRun: Bool) -> Int64? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return nil } // SAFETY: path derived from CLI working directory

        let size = directorySize(at: path)
        guard !dryRun else { return size }

        // Try removing contents first (works better with file-sync tools watching the tree)
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path) // SAFETY: enumerates build artifacts in project directory
            for item in contents {
                let itemPath = (path as NSString).appendingPathComponent(item)
                do {
                    try fileManager.removeItem(atPath: itemPath) // SAFETY: removes build artifacts under project .build/
                } catch {
                    Self.logger.warning("Failed to remove build artifact: \(itemPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Self.logger.warning("Failed to list build directory contents: \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        // Then try removing the directory itself
        do {
            try fileManager.removeItem(atPath: path) // SAFETY: removes build artifact directory in project
        } catch {
            Self.logger.warning("Failed to remove build directory: \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return size
    }

    private func findDirectories(named name: String, in path: String) -> [String] {
        let fileManager = FileManager.default
        var results: [String] = []

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }

        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == name {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), // SAFETY: scans project tree for .docc-build dirs
                   isDirectory.boolValue {
                    results.append(url.path)
                    enumerator.skipDescendants()
                }
            }
        }

        return results
    }

    private func directorySize(at path: String) -> Int64 {
        let fileManager = FileManager.default
        var size: Int64 = 0

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        ) else {
            return 0
        }

        while let url = enumerator.nextObject() as? URL {
            do {
                if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    size += Int64(fileSize)
                }
            } catch {
                Self.logger.warning("Could not read file size for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return size
    }

    private func runGitGC() -> (success: Bool, error: String?) {
        // SAFETY: runs git gc to reclaim disk space
        do {
            let result = try ProcessRunner.run(
                "/usr/bin/git",
                arguments: ["gc", "--aggressive", "--prune=now"]
            )

            if result.exitCode == 0 {
                return (true, nil)
            } else {
                let errorString = result.stderr.isEmpty ? "Unknown error" : result.stderr
                return (false, errorString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            Self.logger.warning("Git gc failed: \(error.localizedDescription, privacy: .public)")
            return (false, error.localizedDescription)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
