import Foundation
import Testing
@testable import MemoryBuilder

@Suite("ADRExtractor")
struct ADRExtractorTests {

    let extractor = ADRExtractor()

    @Test("Extracts ADR entries from decisions log")
    func extractsADRs() async throws {
        let tmpDir = try createFixtureWithADRs("""
        # Architecture Decisions Log

        ## Decisions

        ```yaml
        id: ADR-001
        date: 2025-01-15
        status: accepted
        category: api
        title: Use actors for shared state
        decision: |
          All shared mutable state uses Swift actors.
        ```

        ```yaml
        id: ADR-002
        date: 2025-02-01
        status: accepted
        category: testing
        title: TDD workflow mandatory
        decision: |
          All features follow red/green/refactor.
        ```
        """)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir,
            guidelinesPath: "development-guidelines",
            globalClaudeMD: nil
        )

        #expect(entries.count == 1)
        let body = entries.first?.body ?? ""
        #expect(body.contains("ADR-001"))
        #expect(body.contains("ADR-002"))
        #expect(body.contains("Use actors for shared state"))
        #expect(body.contains("TDD workflow mandatory"))
    }

    @Test("Skips superseded ADRs")
    func skipsSuperseded() async throws {
        let tmpDir = try createFixtureWithADRs("""
        # Architecture Decisions Log

        ## Decisions

        ```yaml
        id: ADR-001
        date: 2025-01-15
        status: superseded
        category: api
        title: Old approach
        decision: |
          This was replaced.
        superseded_by: ADR-002
        ```

        ```yaml
        id: ADR-002
        date: 2025-02-01
        status: accepted
        category: api
        title: New approach
        decision: |
          This replaced ADR-001.
        supersedes: ADR-001
        ```
        """)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir,
            guidelinesPath: "development-guidelines",
            globalClaudeMD: nil
        )

        let body = entries.first?.body ?? ""
        #expect(body.contains("ADR-002"))
        #expect(body.contains("New approach"))
        // Superseded ADR should not appear in summary
        #expect(!body.contains("Old approach"))
    }

    @Test("Returns empty when no ADR file exists")
    func noADRFile() async throws {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir,
            guidelinesPath: "development-guidelines",
            globalClaudeMD: nil
        )

        #expect(entries.isEmpty)
    }

    @Test("Memory entry has correct type and filename")
    func correctMetadata() async throws {
        let tmpDir = try createFixtureWithADRs("""
        # Architecture Decisions Log

        ## Decisions

        ```yaml
        id: ADR-001
        date: 2025-01-15
        status: accepted
        category: api
        title: Test decision
        decision: |
          Something.
        ```
        """)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir,
            guidelinesPath: "development-guidelines",
            globalClaudeMD: nil
        )

        #expect(entries.first?.type == "project")
        #expect(entries.first?.filename == "project_decisions.md")
    }

    // MARK: - Helpers

    private func createFixtureWithADRs(_ content: String) throws -> String {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderTest-\(UUID().uuidString)"
        let adrDir = tmpDir + "/development-guidelines/00_CORE_RULES"
        try FileManager.default.createDirectory(atPath: adrDir, withIntermediateDirectories: true)
        try content.write(
            toFile: adrDir + "/06_ARCHITECTURE_DECISIONS.md",
            atomically: true,
            encoding: .utf8
        )
        return tmpDir
    }
}
