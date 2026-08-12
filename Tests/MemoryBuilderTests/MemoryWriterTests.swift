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

    // MARK: - The `memory-index` region

    private static let profile = MemoryEntry(
        filename: "project_profile.md",
        name: "Project Profile",
        description: "Swift package structure and dependencies",
        type: "project",
        body: ""
    )

    @Test("Generated entries are written as one region, not as N tagged lines")
    func writesARegion() {
        let result = MemoryWriter.mergeIndex(existing: "", entries: [Self.profile])

        #expect(result.contains("<!-- generated:memory-index -->"))
        #expect(result.contains("<!-- /generated:memory-index -->"))
        // The per-line marker is what made deletion inexpressible; it is gone.
        #expect(!result.contains("— Swift package structure and dependencies <!-- generated -->"))
    }

    @Test("A line that lost its marker is deleted, not made immortal")
    func staleDuplicateIsDeleted() {
        // The defect the region form exists to fix. `mergeIndex` used to partition on the
        // line-suffix marker, so a generated line that lost its tag — a hand edit, a merge, a
        // generator whose output shape changed — could never be told from a line a human
        // wrote, and therefore could never be removed. The live index carried five such pairs:
        // two entries pointing at one file, one saying 72 targets and one saying 116, both
        // loaded, the reader told the truth and its stale contradiction in the same list.
        //
        // Identity is the link target, which is the one thing both lines agree on.
        let existing = """
        - [Project Profile](project_profile.md) — quality-gate-swift — Swift 6.2, 72+ targets
        - [Project Profile](project_profile.md) — Module dependency graph <!-- generated -->
        """

        let result = MemoryWriter.mergeIndex(existing: existing, entries: [Self.profile])

        #expect(result.components(separatedBy: "project_profile.md").count - 1 == 1)
        #expect(!result.contains("72+ targets"))
        #expect(result.contains("Swift package structure and dependencies"))
    }

    @Test("A manual line about a file nothing generates is untouched")
    func unrelatedManualLineSurvives() {
        let existing = "- [My Custom Note](custom_note.md) — something I wrote\n"

        let result = MemoryWriter.mergeIndex(existing: existing, entries: [Self.profile])

        #expect(result.contains("- [My Custom Note](custom_note.md) — something I wrote"))
    }

    @Test("Prose outside the region is preserved, including a heading above it")
    func proseIsPreserved() {
        let existing = """
        # Project memory

        Read this at session start.

        - [My Custom Note](custom_note.md) — something I wrote
        """

        let result = MemoryWriter.mergeIndex(existing: existing, entries: [Self.profile])

        #expect(result.contains("# Project memory"))
        #expect(result.contains("Read this at session start."))
    }

    @Test("An existing region is rewritten where it sits, not moved to the end")
    func regionIsRewrittenInPlace() {
        let existing = """
        # Project memory

        <!-- generated:memory-index -->
        - [Project Profile](project_profile.md) — an old description
        - [Departed](departed.md) — a memory that no longer exists
        <!-- /generated:memory-index -->

        Closing prose that must stay last.
        """

        let result = MemoryWriter.mergeIndex(existing: existing, entries: [Self.profile])
        // The index ends in a newline, so the last element of `lines` is the empty string
        // after it — the last *written* line is the one before.
        let written = result.lines.filter { !$0.isEmpty }

        #expect(!result.contains("departed.md"))
        #expect(!result.contains("an old description"))
        #expect(written.last?.contains("Closing prose") == true)
    }

    @Test("Merging its own output changes nothing")
    func regionMergeIsIdempotent() {
        let once = MemoryWriter.mergeIndex(existing: "", entries: [Self.profile])
        let twice = MemoryWriter.mergeIndex(existing: once, entries: [Self.profile])

        #expect(once == twice)
    }

    @Test("Migrating a legacy index and then re-merging changes nothing the second time")
    func migrationConverges() {
        let legacy = """
        - [Project Profile](project_profile.md) — stale, untagged, and previously immortal
        - [Project Profile](project_profile.md) — stale but tagged <!-- generated -->
        - [My Custom Note](custom_note.md) — mine
        """

        let migrated = MemoryWriter.mergeIndex(existing: legacy, entries: [Self.profile])
        let again = MemoryWriter.mergeIndex(existing: migrated, entries: [Self.profile])

        #expect(migrated == again)
        #expect(migrated.contains("custom_note.md"))
        #expect(migrated.components(separatedBy: "project_profile.md").count - 1 == 1)
    }
}
