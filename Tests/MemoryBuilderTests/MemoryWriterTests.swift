import Foundation
import Testing
@testable import MemoryBuilder

@Suite("MemoryWriter")
struct MemoryWriterTests {

    // MARK: - render()

    @Test("Renders entry with correct frontmatter including generated-by tag")
    func renderFrontmatter() {
        let entry = MemoryEntry(
            filename: "project_profile.md",
            name: "Project Profile",
            description: "Swift package structure and dependencies",
            type: "project",
            body: "This is a Swift package with 3 modules."
        )
        let output = MemoryWriter.render(entry)

        #expect(output.contains("---"))
        #expect(output.contains("name: Project Profile"))
        #expect(output.contains("description: Swift package structure and dependencies"))
        #expect(output.contains("type: project"))
        #expect(output.contains(MemoryWriter.generatedTag))
        #expect(output.contains("This is a Swift package with 3 modules."))
    }

    @Test("Rendered output has frontmatter before body")
    func renderOrder() {
        let entry = MemoryEntry(
            filename: "test.md",
            name: "Test",
            description: "A test entry",
            type: "project",
            body: "Body content here."
        )
        let output = MemoryWriter.render(entry)
        let parts = output.components(separatedBy: "---")
        // Should be: empty before first ---, frontmatter, body after second ---
        #expect(parts.count >= 3)
    }

    // MARK: - indexLine()

    @Test("Index line contains filename and description")
    func indexLine() {
        let entry = MemoryEntry(
            filename: "project_profile.md",
            name: "Project Profile",
            description: "Swift package structure and dependencies",
            type: "project",
            body: ""
        )
        let line = MemoryWriter.indexLine(for: entry)

        #expect(line.contains("project_profile.md"))
        #expect(line.contains("Project Profile"))
    }

    @Test("Index line is under 150 characters")
    func indexLineLength() {
        let entry = MemoryEntry(
            filename: "project_profile.md",
            name: "Project Profile",
            description: "Swift package structure and dependencies",
            type: "project",
            body: ""
        )
        let line = MemoryWriter.indexLine(for: entry)
        #expect(line.count <= 150)
    }

    // MARK: - isGenerated()

    @Test("Detects generated files by frontmatter tag")
    func isGeneratedTrue() {
        let content = """
        ---
        name: Project Profile
        description: test
        type: project
        generated-by: memory-builder
        ---

        Some body.
        """
        #expect(MemoryWriter.isGenerated(content))
    }

    @Test("Does not flag manually-written files as generated")
    func isGeneratedFalse() {
        let content = """
        ---
        name: My Custom Memory
        description: something I wrote myself
        type: feedback
        ---

        Don't touch this.
        """
        #expect(!MemoryWriter.isGenerated(content))
    }

    // MARK: - mergeIndex()

    @Test("Adds new entries to empty MEMORY.md")
    func mergeIntoEmpty() {
        let entries = [
            MemoryEntry(
                filename: "project_profile.md",
                name: "Project Profile",
                description: "Package info",
                type: "project",
                body: ""
            )
        ]
        let result = MemoryWriter.mergeIndex(existing: "", entries: entries)
        #expect(result.contains("project_profile.md"))
    }

    @Test("Preserves manually-written lines in MEMORY.md")
    func mergePreservesManual() {
        let existing = "- [My Custom Note](custom_note.md) — something I wrote\n"
        let entries = [
            MemoryEntry(
                filename: "project_profile.md",
                name: "Project Profile",
                description: "Package info",
                type: "project",
                body: ""
            )
        ]
        let result = MemoryWriter.mergeIndex(existing: existing, entries: entries)
        #expect(result.contains("My Custom Note"))
        #expect(result.contains("project_profile.md"))
    }

    @Test("Updates existing generated lines in MEMORY.md")
    func mergeUpdatesGenerated() {
        let existing = "- [Project Profile](project_profile.md) — old description <!-- generated -->\n"
        let entries = [
            MemoryEntry(
                filename: "project_profile.md",
                name: "Project Profile",
                description: "New description",
                type: "project",
                body: ""
            )
        ]
        let result = MemoryWriter.mergeIndex(existing: existing, entries: entries)
        // Should have the new description, not the old one
        #expect(result.contains("New description"))
        #expect(!result.contains("old description"))
    }

    @Test("Does not duplicate entries on repeated merge")
    func mergeIdempotent() {
        let entries = [
            MemoryEntry(
                filename: "project_profile.md",
                name: "Project Profile",
                description: "Package info",
                type: "project",
                body: ""
            )
        ]
        let first = MemoryWriter.mergeIndex(existing: "", entries: entries)
        let second = MemoryWriter.mergeIndex(existing: first, entries: entries)

        let count = second.components(separatedBy: "project_profile.md").count - 1
        #expect(count == 1)
    }
}
