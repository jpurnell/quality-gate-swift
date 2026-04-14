import Foundation
import Yams

/// Extracts ADR summary from the architecture decisions log.
public struct ADRExtractor: MemoryExtractor, Sendable {
    public let id = "adrSummary"

    public init() {}

    public func extract(
        projectRoot: String,
        guidelinesPath: String,
        globalClaudeMD: String?
    ) async throws -> [MemoryEntry] {
        let adrPath = [projectRoot, guidelinesPath, "00_CORE_RULES", "06_ARCHITECTURE_DECISIONS.md"]
            .joined(separator: "/")

        guard FileManager.default.fileExists(atPath: adrPath) else { return [] } // SAFETY: reads ADR file from project guidelines dir
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
        lines.append("Full details: `\(guidelinesPath)/00_CORE_RULES/06_ARCHITECTURE_DECISIONS.md`")

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

            guard let parsed = try? Yams.load(yaml: yamlBlock) as? [String: Any] else { continue }

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
