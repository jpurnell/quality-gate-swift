import Foundation

/// Extracts coding conventions from project CLAUDE.md and rules files.
/// Skips content already present in the global ~/.claude/CLAUDE.md.
public struct ConventionExtractor: MemoryExtractor, Sendable {
    /// Unique identifier for this extractor.
    public let id = "conventions"

    /// Creates a new convention extractor.
    public init() {}

    /// Reads the project CLAUDE.md, filters out sections duplicated in global CLAUDE.md, and returns the remainder.
    public func extract(
        projectRoot: String,
        guidelinesPath: String,
        globalClaudeMD: String?
    ) async throws -> [MemoryEntry] {
        // Read project-level CLAUDE.md
        let claudePath = (projectRoot as NSString).appendingPathComponent("CLAUDE.md")
        guard FileManager.default.fileExists(atPath: claudePath) else { return [] } // SAFETY: reads CLAUDE.md from project root
        let projectClaude = try String(contentsOfFile: claudePath, encoding: .utf8)

        // Extract H2 sections from the project CLAUDE.md
        let sections = extractSections(from: projectClaude)

        // Filter out sections whose headings also appear in global CLAUDE.md
        let globalHeadings: Set<String>
        if let global = globalClaudeMD {
            globalHeadings = Set(extractSections(from: global).map(\.heading))
        } else {
            globalHeadings = []
        }

        let unique = sections.filter { !globalHeadings.contains($0.heading) }
        guard !unique.isEmpty else { return [] }

        var lines: [String] = []
        lines.append("Project-specific conventions from CLAUDE.md:\n")
        for section in unique {
            lines.append("### \(section.heading)")
            lines.append(section.body.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }

        return [
            MemoryEntry(
                filename: "feedback_conventions.md",
                name: "Project Conventions",
                description: "Project-specific rules not in global CLAUDE.md",
                type: "feedback",
                body: lines.joined(separator: "\n")
            )
        ]
    }

    // MARK: - Parsing

    private struct Section {
        let heading: String
        let body: String
    }

    /// Split markdown into H2 sections.
    private func extractSections(from markdown: String) -> [Section] {
        var sections: [Section] = []
        var currentHeading: String?
        var currentBody: [String] = []

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                // Save previous section
                if let heading = currentHeading {
                    sections.append(Section(heading: heading, body: currentBody.joined(separator: "\n")))
                }
                currentHeading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentBody = []
            } else if currentHeading != nil {
                currentBody.append(line)
            }
        }
        // Save final section
        if let heading = currentHeading {
            sections.append(Section(heading: heading, body: currentBody.joined(separator: "\n")))
        }

        return sections
    }
}
