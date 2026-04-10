import Foundation
import Testing
@testable import MemoryBuilder

@Suite("ConventionExtractor")
struct ConventionExtractorTests {

    let extractor = ConventionExtractor()

    @Test("Extracts project-specific sections from CLAUDE.md")
    func extractsProjectSections() async throws {
        let tmpDir = try createFixture(
            projectClaude: """
            # MyProject

            ## Quality Gate
            Run quality-gate before every commit.

            ## Custom Rules
            Always use actors for shared state.
            """,
            globalClaude: nil
        )
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: nil
        )

        #expect(entries.count == 1)
        let body = entries.first?.body ?? ""
        #expect(body.contains("Quality Gate"))
        #expect(body.contains("Custom Rules"))
    }

    @Test("Filters out sections that exist in global CLAUDE.md")
    func filtersGlobalSections() async throws {
        let globalClaude = """
        ## Swift Development
        Target Swift 6.x with strict concurrency.

        ## Deployment
        Check version compatibility first.
        """

        let tmpDir = try createFixture(
            projectClaude: """
            # MyProject

            ## Swift Development
            Target Swift 6.x with strict concurrency.

            ## Project-Specific Feature
            This is unique to this project.
            """,
            globalClaude: nil
        )
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: globalClaude
        )

        let body = entries.first?.body ?? ""
        #expect(body.contains("Project-Specific Feature"))
        #expect(!body.contains("Swift Development"))
    }

    @Test("Returns empty when no CLAUDE.md exists")
    func noClaude() async throws {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: nil
        )
        #expect(entries.isEmpty)
    }

    @Test("Returns empty when all sections are global")
    func allGlobal() async throws {
        let content = """
        ## Swift Development
        Target Swift 6.x.
        """

        let tmpDir = try createFixture(projectClaude: content, globalClaude: nil)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: content
        )
        #expect(entries.isEmpty)
    }

    @Test("Memory entry has feedback type")
    func correctType() async throws {
        let tmpDir = try createFixture(
            projectClaude: "## Something\nA rule.",
            globalClaude: nil
        )
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: nil
        )
        #expect(entries.first?.type == "feedback")
    }

    private func createFixture(projectClaude: String, globalClaude: String?) throws -> String {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try projectClaude.write(toFile: tmpDir + "/CLAUDE.md", atomically: true, encoding: .utf8)
        return tmpDir
    }
}
