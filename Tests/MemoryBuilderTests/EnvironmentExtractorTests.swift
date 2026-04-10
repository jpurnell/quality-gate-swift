import Foundation
import Testing
@testable import MemoryBuilder

@Suite("EnvironmentExtractor")
struct EnvironmentExtractorTests {

    let extractor = EnvironmentExtractor()

    @Test("Produces at least one entry")
    func producesEntry() async throws {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: nil
        )

        #expect(entries.count == 1)
    }

    @Test("Includes platform info")
    func includesPlatform() async throws {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: nil
        )

        let body = entries.first?.body ?? ""
        #expect(body.contains("Platform"))
    }

    @Test("Includes Swift version")
    func includesSwiftVersion() async throws {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: nil
        )

        let body = entries.first?.body ?? ""
        #expect(body.contains("Swift"))
    }

    @Test("Has reference type")
    func correctType() async throws {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: nil
        )

        #expect(entries.first?.type == "reference")
    }
}
