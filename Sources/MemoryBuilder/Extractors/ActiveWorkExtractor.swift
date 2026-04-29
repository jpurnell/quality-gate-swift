import Foundation

/// Extracts active work from implementation checklists and git log.
public struct ActiveWorkExtractor: MemoryExtractor, Sendable {
    /// Unique identifier for this extractor.
    public let id = "activeWork"

    /// Creates a new active work extractor.
    public init() {}

    /// Gathers current branch, recent commits, and active checklists into a memory entry.
    public func extract(
        projectRoot: String,
        guidelinesPath: String,
        globalClaudeMD: String?
    ) async throws -> [MemoryEntry] {
        var lines: [String] = []

        // 1. Current branch
        let branch = runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: projectRoot)
        if let branch, !branch.isEmpty {
            lines.append("**Current branch:** `\(branch)`")
        }

        // 2. Recent commits
        let log = runGit(["log", "--oneline", "-10"], in: projectRoot)
        if let log, !log.isEmpty {
            lines.append("")
            lines.append("**Recent commits:**")
            for commit in log.components(separatedBy: "\n").prefix(10) where !commit.isEmpty {
                lines.append("- \(commit)")
            }
        }

        // 3. Active checklists
        let checklistDir = [projectRoot, guidelinesPath, "04_IMPLEMENTATION_CHECKLISTS"]
            .joined(separator: "/")
        let checklists = findCurrentChecklists(in: checklistDir)
        if !checklists.isEmpty {
            lines.append("")
            lines.append("**Active checklists:**")
            for checklist in checklists {
                lines.append("- `\(checklist)`")
            }
        }

        guard !lines.isEmpty else { return [] }

        return [
            MemoryEntry(
                filename: "project_active_work.md",
                name: "Active Work",
                description: "Current branch, recent commits, and active checklists",
                type: "project",
                body: lines.joined(separator: "\n")
            )
        ]
    }

    // MARK: - Helpers

    private func runGit(_ args: [String], in directory: String) -> String? {
        let process = Process() // SAFETY: runs git to detect active work (log, diff, branch)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func findCurrentChecklists(in directory: String) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory) else { return [] } // SAFETY: lists checklist files in project guidelines dir
        return items
            .filter { $0.hasPrefix("CURRENT_") && $0.hasSuffix(".md") }
            .sorted()
    }
}
