import Foundation
import Testing
@testable import MemoryBuilder
@testable import QualityGateCore

@Suite("MemoryFileValidator Tests")
struct MemoryValidatorTests {

    // MARK: - Index Link Validation

    @Test("Detects broken index link")
    func detectsBrokenLink() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let indexContent = """
        # Memory Index
        - [Profile](project_profile.md) — Project overview
        - [Missing](nonexistent.md) — This file doesn't exist
        """
        let indexPath = tmpDir.appendingPathComponent("MEMORY.md")
        try indexContent.write(to: indexPath, atomically: true, encoding: .utf8)

        // Create only the profile file, not the nonexistent one
        try "content".write(
            to: tmpDir.appendingPathComponent("project_profile.md"),
            atomically: true, encoding: .utf8
        )

        let diags = MemoryFileValidator.validateIndexLinks(
            indexContent: indexContent,
            memoryDir: tmpDir.path,
            indexPath: indexPath.path
        )

        #expect(diags.count == 1)
        #expect(diags[0].ruleId == "memory.broken-index-link")
        #expect(diags[0].message.contains("nonexistent.md"))
    }

    @Test("Passes when all index links are valid")
    func passesValidLinks() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let indexContent = """
        - [Profile](profile.md) — Project profile
        - [Arch](arch.md) — Architecture
        """
        let indexPath = tmpDir.appendingPathComponent("MEMORY.md")
        try indexContent.write(to: indexPath, atomically: true, encoding: .utf8)

        try "content".write(
            to: tmpDir.appendingPathComponent("profile.md"),
            atomically: true, encoding: .utf8
        )
        try "content".write(
            to: tmpDir.appendingPathComponent("arch.md"),
            atomically: true, encoding: .utf8
        )

        let diags = MemoryFileValidator.validateIndexLinks(
            indexContent: indexContent,
            memoryDir: tmpDir.path,
            indexPath: indexPath.path
        )

        #expect(diags.isEmpty)
    }

    // MARK: - Generated File Validation

    @Test("Detects missing frontmatter in generated file")
    func detectsMissingFrontmatter() {
        let diags = MemoryFileValidator.validateGeneratedFile(
            content: "No frontmatter here, just text.",
            filePath: "/tmp/bad.md",
            fileName: "bad.md"
        )

        #expect(diags.count == 1)
        #expect(diags[0].ruleId == "memory.malformed-generated")
    }

    @Test("Detects empty body in generated file")
    func detectsEmptyBody() {
        let content = """
        ---
        name: Empty
        description: Empty file
        type: project
        generated-by: memory-builder
        ---
        """

        let diags = MemoryFileValidator.validateGeneratedFile(
            content: content,
            filePath: "/tmp/empty.md",
            fileName: "empty.md"
        )

        #expect(diags.count == 1)
        #expect(diags[0].ruleId == "memory.empty-generated")
    }

    @Test("Passes for well-formed generated file")
    func passesWellFormed() {
        let content = """
        ---
        name: Profile
        description: Project profile
        type: project
        generated-by: memory-builder
        ---

        This is a well-formed memory file with real content.
        """

        let diags = MemoryFileValidator.validateGeneratedFile(
            content: content,
            filePath: "/tmp/good.md",
            fileName: "good.md"
        )

        #expect(diags.isEmpty)
    }

    // MARK: - Full Validation

    @Test("Full validate skips manual files")
    func skipsManualFiles() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Manual file (no generated-by tag)
        let manualContent = """
        ---
        name: Manual
        description: Manually written
        type: user
        ---

        This was written by hand.
        """
        try manualContent.write(
            to: tmpDir.appendingPathComponent("manual.md"),
            atomically: true, encoding: .utf8
        )

        // Index
        try "# Memory".write(
            to: tmpDir.appendingPathComponent("MEMORY.md"),
            atomically: true, encoding: .utf8
        )

        let diags = MemoryFileValidator.validate(
            memoryDir: tmpDir.path,
            projectRoot: tmpDir.path,
            packagePath: tmpDir.appendingPathComponent("Package.swift").path
        )

        // Manual file should not produce any malformed/empty diagnostics
        #expect(!diags.contains { $0.ruleId == "memory.malformed-generated" })
        #expect(!diags.contains { $0.ruleId == "memory.empty-generated" })
    }
}
