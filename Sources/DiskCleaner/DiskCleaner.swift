import Foundation
import QualityGateCore

/// Cleans up build artifacts and optimizes git repository.
///
/// This checker removes:
/// - `.build/` directories (Swift Package Manager artifacts)
/// - `.docc-build/` directories (DocC build artifacts)
/// - Optionally runs `git gc` to compress git history
///
/// ## Usage
///
/// ```swift
/// let cleaner = DiskCleaner()
/// let result = try await cleaner.check(configuration: config)
/// ```
public struct DiskCleaner: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "disk-clean"

    /// Human-readable name for this checker.
    public let name = "Disk Cleaner"

    /// Creates a new DiskCleaner instance.
    public init() {}

    /// Run disk cleanup on the current directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath

        var diagnostics: [Diagnostic] = []
        var totalBytesFreed: Int64 = 0

        // Clean .build directory
        let buildPath = (currentDir as NSString).appendingPathComponent(".build")
        if let freed = cleanDirectory(at: buildPath, name: ".build") {
            totalBytesFreed += freed
            diagnostics.append(Diagnostic(
                severity: .note,
                message: "Removed .build/ (\(formatBytes(freed)))",
                ruleId: "disk-clean-build"
            ))
        }

        // Find and clean .docc-build directories recursively
        let doccBuildPaths = findDirectories(named: ".docc-build", in: currentDir)
        for doccPath in doccBuildPaths {
            if let freed = cleanDirectory(at: doccPath, name: ".docc-build") {
                totalBytesFreed += freed
                let relativePath = doccPath.replacingOccurrences(of: currentDir + "/", with: "")
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: "Removed \(relativePath) (\(formatBytes(freed)))",
                    ruleId: "disk-clean-docc"
                ))
            }
        }

        // Run git gc if this is a git repository
        let gitPath = (currentDir as NSString).appendingPathComponent(".git")
        if fileManager.fileExists(atPath: gitPath) { // SAFETY: checks .git in CLI working directory
            let gitSizeBefore = directorySize(at: gitPath)

            let gcResult = runGitGC()
            if gcResult.success {
                let gitSizeAfter = directorySize(at: gitPath)
                let freed = gitSizeBefore - gitSizeAfter
                if freed > 0 {
                    totalBytesFreed += freed
                    diagnostics.append(Diagnostic(
                        severity: .note,
                        message: "Git gc freed \(formatBytes(freed))",
                        ruleId: "disk-clean-git"
                    ))
                }
            } else if let error = gcResult.error {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Git gc failed: \(error)",
                    ruleId: "disk-clean-git-error"
                ))
            }
        }

        // Summary diagnostic
        if totalBytesFreed > 0 {
            diagnostics.insert(Diagnostic(
                severity: .note,
                message: "Total disk space freed: \(formatBytes(totalBytesFreed))",
                ruleId: "disk-clean-summary"
            ), at: 0)
        } else {
            diagnostics.append(Diagnostic(
                severity: .note,
                message: "No build artifacts to clean",
                ruleId: "disk-clean-none"
            ))
        }

        let duration = ContinuousClock.now - startTime

        return CheckResult(
            checkerId: id,
            status: .passed,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    // MARK: - Private Implementation

    private func cleanDirectory(at path: String, name: String) -> Int64? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return nil } // SAFETY: path derived from CLI working directory

        let size = directorySize(at: path)

        // Try removing contents first (works better with Dropbox sync)
        if let contents = try? fileManager.contentsOfDirectory(atPath: path) { // SAFETY: enumerates build artifacts in project directory
            for item in contents {
                let itemPath = (path as NSString).appendingPathComponent(item)
                try? fileManager.removeItem(atPath: itemPath) // SAFETY: removes build artifacts under project .build/
            }
        }
        // Then try removing the directory itself
        try? fileManager.removeItem(atPath: path) // SAFETY: removes build artifact directory in project
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
            if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(fileSize)
            }
        }

        return size
    }

    private func runGitGC() -> (success: Bool, error: String?) {
        let process = Process() // SAFETY: runs git gc to reclaim disk space
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["gc", "--aggressive", "--prune=now"]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return (true, nil)
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                return (false, errorString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
