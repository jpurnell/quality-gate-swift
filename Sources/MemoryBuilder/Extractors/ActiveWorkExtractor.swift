import Foundation
import os
import QualityGateCore

/// Extracts active work from implementation checklists and git log.
public struct ActiveWorkExtractor: MemoryExtractor, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "ActiveWorkExtractor")
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
        // SAFETY: runs git to detect active work (log, diff, branch)
        do {
            let result = try ProcessRunner.run(
                "/usr/bin/git",
                arguments: args,
                currentDirectory: directory
            )
            guard result.exitCode == 0 else { return nil }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Self.logger.warning("Git command failed in \(directory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func findCurrentChecklists(in directory: String) -> [String] {
        let fm = FileManager.default
        let items: [String]
        do {
            items = try fm.contentsOfDirectory(atPath: directory) // SAFETY: lists checklist files in project guidelines dir
        } catch {
            Self.logger.warning("Could not list checklist directory \(directory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
        return items
            .filter { $0.hasPrefix("CURRENT_") && $0.hasSuffix(".md") }
            .sorted()
    }
}
