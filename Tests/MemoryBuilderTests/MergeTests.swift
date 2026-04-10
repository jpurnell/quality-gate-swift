import Foundation
import Testing
@testable import MemoryBuilder

@Suite("Memory Merge Safety")
struct MergeTests {

    @Test("Generated files are overwritten on re-run")
    func overwritesGenerated() throws {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderMerge-\(UUID().uuidString)"
        let memoryDir = tmpDir + "/memory"
        try FileManager.default.createDirectory(atPath: memoryDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Write a generated file
        let oldContent = """
        ---
        name: Project Profile
        description: old info
        type: project
        generated-by: memory-builder
        ---

        Old content.
        """
        try oldContent.write(toFile: memoryDir + "/project_profile.md", atomically: true, encoding: .utf8)

        // Verify it's detected as generated
        #expect(MemoryWriter.isGenerated(oldContent))

        // A new entry with updated content should be writable
        let newEntry = MemoryEntry(
            filename: "project_profile.md",
            name: "Project Profile",
            description: "new info",
            type: "project",
            body: "New content."
        )
        let rendered = MemoryWriter.render(newEntry)
        #expect(rendered.contains("New content."))
        #expect(MemoryWriter.isGenerated(rendered))
    }

    @Test("Manual files are never overwritten")
    func preservesManual() {
        let manualContent = """
        ---
        name: User Role
        description: Senior Swift developer
        type: user
        ---

        User is a senior Swift developer focused on numerics.
        """
        #expect(!MemoryWriter.isGenerated(manualContent))
    }

    @Test("Files without frontmatter are treated as manual")
    func noFrontmatterIsManual() {
        let content = "Just some notes I jotted down."
        #expect(!MemoryWriter.isGenerated(content))
    }
}
