import Foundation
import QualityGateCore

/// Generates and updates `.claude/memory/` files by analyzing project state.
///
/// MemoryBuilder extracts project profile, architecture, conventions, active work,
/// ADR summaries, and environment info from the codebase and writes them as
/// tagged memory files that Claude Code loads at session start.
public struct MemoryBuilder: QualityChecker, Sendable {
    /// Unique checker identifier used in diagnostics and CLI filtering.
    public let id = "memory-builder"
    /// Human-readable name shown in check results.
    public let name = "Memory Builder"

    /// Relative path to the development-guidelines directory.
    private let guidelinesPath: String

    /// Creates a MemoryBuilder targeting the given guidelines directory.
    /// - Parameter guidelinesPath: Relative path from project root to the development-guidelines directory.
    public init(guidelinesPath: String = "development-guidelines") {
        self.guidelinesPath = guidelinesPath
    }

    /// Runs all extractors, writes memory files, and validates the result.
    /// - Parameter configuration: The quality-gate configuration for this run.
    /// - Returns: A check result with diagnostics for each written or skipped file.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let projectRoot = FileManager.default.currentDirectoryPath

        // Load global CLAUDE.md for deduplication
        let globalClaudePath = NSHomeDirectory() + "/.claude/CLAUDE.md"
        let globalClaudeMD = try? String(contentsOfFile: globalClaudePath, encoding: .utf8)

        // Auto-detect memory output path
        let memoryDir = detectMemoryDir(projectRoot: projectRoot)
        var diagnostics: [Diagnostic] = []

        // Run all extractors
        let extractors: [any MemoryExtractor] = [
            ProjectProfileExtractor(),
            ArchitectureExtractor(),
            ConventionExtractor(),
            ActiveWorkExtractor(),
            ADRExtractor(),
            EnvironmentExtractor(),
        ]

        var allEntries: [MemoryEntry] = []
        for extractor in extractors {
            do {
                let entries = try await extractor.extract(
                    projectRoot: projectRoot,
                    guidelinesPath: guidelinesPath,
                    globalClaudeMD: globalClaudeMD
                )
                allEntries.append(contentsOf: entries)
            } catch {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Extractor '\(extractor.id)' failed: \(error.localizedDescription)",
                    ruleId: "memory-builder.\(extractor.id)-failed"
                ))
            }
        }

        // Write memory files
        if let memoryDir {
            let fm = FileManager.default
            if !fm.fileExists(atPath: memoryDir) { // SAFETY: checks .claude/memory dir derived from project root
                try fm.createDirectory(atPath: memoryDir, withIntermediateDirectories: true) // SAFETY: creates .claude/memory output dir
            }

            for entry in allEntries {
                let filePath = (memoryDir as NSString).appendingPathComponent(entry.filename)

                // Only overwrite if the file is generated or doesn't exist
                if fm.fileExists(atPath: filePath) { // SAFETY: checks generated memory file in .claude/memory
                    let existing = try String(contentsOfFile: filePath, encoding: .utf8)
                    guard MemoryWriter.isGenerated(existing) else {
                        diagnostics.append(Diagnostic(
                            severity: .note,
                            message: "Skipped \(entry.filename) — manually written",
                            ruleId: "memory-builder.skip-manual"
                        ))
                        continue
                    }
                }

                let rendered = MemoryWriter.render(entry)
                try rendered.write(toFile: filePath, atomically: true, encoding: .utf8)
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: "Updated \(entry.filename)",
                    ruleId: "memory-builder.updated"
                ))
            }

            // Update MEMORY.md index
            let indexPath = (memoryDir as NSString).appendingPathComponent("MEMORY.md")
            let existingIndex = (try? String(contentsOfFile: indexPath, encoding: .utf8)) ?? ""
            let newIndex = MemoryWriter.mergeIndex(existing: existingIndex, entries: allEntries)
            try newIndex.write(toFile: indexPath, atomically: true, encoding: .utf8)
            // Post-extraction validation
            let packagePath = (projectRoot as NSString).appendingPathComponent("Package.swift")
            let validationDiags = MemoryFileValidator.validate(
                memoryDir: memoryDir,
                projectRoot: projectRoot,
                packagePath: packagePath
            )
            diagnostics.append(contentsOf: validationDiags)
        } else {
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "Could not detect .claude/ memory directory — skipping file writes",
                ruleId: "memory-builder.no-output-dir"
            ))
        }

        let duration = ContinuousClock.now - startTime
        let hasWarnings = diagnostics.contains { $0.severity == .warning }
        return CheckResult(
            checkerId: id,
            status: hasWarnings ? .warning : .passed,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    // MARK: - Path Detection

    /// Detect the .claude/projects/.../memory/ directory.
    ///
    /// Strategy: look for CLAUDE_PROJECT_DIR env var, then walk up from cwd
    /// to find a .claude/ directory with a projects/ subdirectory.
    private func detectMemoryDir(projectRoot: String) -> String? {
        // Try CLAUDE_PROJECT_DIR first
        if let envDir = ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"] {
            let memDir = (envDir as NSString).appendingPathComponent("memory")
            return memDir
        }

        // Fall back: construct the Claude project path from the project root
        // Claude uses ~/.claude/projects/<mangled-path>/memory/
        let home = NSHomeDirectory()
        let mangled = projectRoot.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let memDir = "\(home)/.claude/projects/-\(mangled)/memory"
        return memDir
    }
}
