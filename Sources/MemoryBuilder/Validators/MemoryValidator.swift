import Foundation
import os
import QualityGateCore

/// Validates generated memory files against current project state.
///
/// Runs after extraction to catch drift in previously-generated memory,
/// extractor bugs, and broken index links.
public enum MemoryFileValidator {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "MemoryFileValidator")

    /// Validate memory files in the given directory against project state.
    ///
    /// - Parameters:
    ///   - memoryDir: Path to the .claude/memory/ directory.
    ///   - projectRoot: Path to the project root.
    ///   - packagePath: Path to Package.swift.
    /// - Returns: Array of diagnostics for any drift detected.
    public static func validate(
        memoryDir: String,
        projectRoot: String,
        packagePath: String
    ) -> [Diagnostic] {
        let fm = FileManager.default
        var diagnostics: [Diagnostic] = []

        // Validate MEMORY.md index links
        let indexPath = (memoryDir as NSString).appendingPathComponent("MEMORY.md")
        do {
            let indexContent = try String(contentsOfFile: indexPath, encoding: .utf8)
            diagnostics.append(contentsOf: validateIndexLinks(
                indexContent: indexContent,
                memoryDir: memoryDir,
                indexPath: indexPath
            ))
        } catch {
            logger.warning("Could not read MEMORY.md index at \(indexPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Validate generated memory files for staleness
        let files: [String]
        do {
            files = try fm.contentsOfDirectory(atPath: memoryDir) // SAFETY: lists generated memory files for validation
        } catch {
            logger.warning("Could not list memory directory \(memoryDir, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return diagnostics
        }
        for file in files where file.hasSuffix(".md") && file != "MEMORY.md" {
            let filePath = (memoryDir as NSString).appendingPathComponent(file)
            let content: String
            do {
                content = try String(contentsOfFile: filePath, encoding: .utf8)
            } catch {
                logger.warning("Skipping unreadable memory file \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }

            // Only validate generated files
            guard MemoryWriter.isGenerated(content) else { continue }

            diagnostics.append(contentsOf: validateGeneratedFile(
                content: content,
                filePath: filePath,
                fileName: file
            ))
        }

        return diagnostics
    }

    // MARK: - Index Link Validation

    /// Check that every link in MEMORY.md points to an existing file.
    static func validateIndexLinks(
        indexContent: String,
        memoryDir: String,
        indexPath: String
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let fm = FileManager.default
        let lines = indexContent.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            // Match markdown links: [Title](filename.md)
            let pattern = #"\[([^\]]+)\]\(([^)]+\.md)\)"#
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern)
            } catch {
                logger.warning("Failed to compile index-link regex: \(error.localizedDescription, privacy: .public)")
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            let matches = regex.matches(in: line, range: range)

            for match in matches {
                guard let fileRange = Range(match.range(at: 2), in: line) else { continue }
                let linkedFile = String(line[fileRange])
                let linkedPath = (memoryDir as NSString).appendingPathComponent(linkedFile)

                if !fm.fileExists(atPath: linkedPath) { // SAFETY: validates index links in .claude/memory
                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "MEMORY.md links to '\(linkedFile)' but file does not exist.",
                        filePath: indexPath,
                        lineNumber: index + 1,
                        ruleId: "memory.broken-index-link",
                        suggestedFix: "Remove the broken link or regenerate memory files"
                    ))
                }
            }
        }

        return diagnostics
    }

    // MARK: - Generated File Validation

    /// Validate a single generated memory file for staleness.
    static func validateGeneratedFile(
        content: String,
        filePath: String,
        fileName: String
    ) -> [Diagnostic] {
        // Check for stale generation date in frontmatter
        // Generated files have: generated-by: memory-builder
        // We could add a generated-date field in future versions
        // For now, just validate the file is non-empty and well-formed

        var diagnostics: [Diagnostic] = []

        // Check frontmatter exists
        guard content.hasPrefix("---") else {
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "Generated memory file '\(fileName)' is missing YAML frontmatter.",
                filePath: filePath,
                ruleId: "memory.malformed-generated",
                suggestedFix: "Regenerate with --check memory-builder"
            ))
            return diagnostics
        }

        // Check body is non-empty
        let parts = content.components(separatedBy: "---")
        if parts.count >= 3 {
            let body = parts[2...].joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Generated memory file '\(fileName)' has empty body.",
                    filePath: filePath,
                    ruleId: "memory.empty-generated",
                    suggestedFix: "Regenerate with --check memory-builder"
                ))
            }
        }

        return diagnostics
    }
}
