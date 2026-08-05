import Foundation
#if canImport(os)
import os
#endif
import Yams

/// Extracts ADR summary from the architecture decisions log.
public struct ADRExtractor: MemoryExtractor, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "ADRExtractor")
    /// Unique identifier for this extractor.
    public let id = "adrSummary"

    /// Creates a new ADR extractor.
    public init() {}

    /// Parses the architecture decisions log and returns a summary of active ADRs.
    public func extract(
        projectRoot: String,
        guidelinesPath: String,
        globalClaudeMD: String?
    ) async throws -> [MemoryEntry] {
        // v2 keeps the decision log with the project that owns it; v1 filed it
        // under the framework's rules. Prefer v2, fall back so unmigrated
        // projects keep working.
        let v2Path = [projectRoot, "project", "decisions", "architecture_decisions.md"]
            .joined(separator: "/")
        let v1Path = [projectRoot, guidelinesPath, "00_CORE_RULES", "06_ARCHITECTURE_DECISIONS.md"]
            .joined(separator: "/")

        let fileManager = FileManager.default
        let adrPath: String
        let displayPath: String
        if fileManager.fileExists(atPath: v2Path) { // SAFETY: reads ADR log from the project's own decisions dir
            adrPath = v2Path
            displayPath = "project/decisions/architecture_decisions.md"
        } else if fileManager.fileExists(atPath: v1Path) { // SAFETY: reads ADR file from project guidelines dir
            adrPath = v1Path
            displayPath = "\(guidelinesPath)/00_CORE_RULES/06_ARCHITECTURE_DECISIONS.md"
        } else {
            return []
        }
        let content = try String(contentsOfFile: adrPath, encoding: .utf8)

        let adrs = parseADRs(from: content)
        let active = adrs.filter { $0.status == "accepted" || $0.status == "amended" }

        guard !active.isEmpty else { return [] }

        var lines: [String] = []
        lines.append("\(active.count) active architectural decisions.\n")
        for adr in active {
            lines.append("- **\(adr.id):** \(adr.title) (\(adr.category))")
        }
        lines.append("")
        lines.append("Full details: `\(displayPath)`")

        return [
            MemoryEntry(
                filename: "project_decisions.md",
                name: "Architecture Decisions",
                description: "\(active.count) active ADRs — query the full log for details",
                type: "project",
                body: lines.joined(separator: "\n")
            )
        ]
    }

    // MARK: - Parsing

    private struct ADREntry {
        let id: String
        let status: String
        let category: String
        let title: String
    }

    /// Parse YAML code blocks from the ADR markdown file.
    private func parseADRs(from content: String) -> [ADREntry] {
        var entries: [ADREntry] = []

        // Split on ```yaml ... ``` blocks
        let parts = content.components(separatedBy: "```yaml")
        for part in parts.dropFirst() {
            guard let endIndex = part.range(of: "```")?.lowerBound else { continue }
            let yamlBlock = String(part[..<endIndex])

            let parsed: [String: Any]
            do {
                guard let loaded = try Yams.load(yaml: yamlBlock) as? [String: Any] else { continue }
                parsed = loaded
            } catch {
                Self.logger.warning("Skipping unparseable ADR YAML block: \(error.localizedDescription, privacy: .public)")
                continue
            }

            guard let id = parsed["id"] as? String,
                  let status = parsed["status"] as? String,
                  let title = parsed["title"] as? String else { continue }

            let category = parsed["category"] as? String ?? "general"

            entries.append(ADREntry(
                id: id,
                status: status,
                category: category,
                title: title
            ))
        }

        return entries
    }
}
