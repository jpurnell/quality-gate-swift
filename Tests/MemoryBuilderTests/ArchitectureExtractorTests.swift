import Foundation
import Testing
@testable import MemoryBuilder

@Suite("ArchitectureExtractor")
struct ArchitectureExtractorTests {

    let extractor = ArchitectureExtractor()

    @Test("Extracts module dependency graph")
    func extractsDependencyGraph() async throws {
        let tmpDir = try createFixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "MyApp",
            targets: [
                .target(name: "Core"),
                .target(name: "Networking", dependencies: ["Core"]),
                .target(name: "UI", dependencies: ["Core", "Networking"]),
                .testTarget(name: "CoreTests", dependencies: ["Core"])
            ]
        )
        """)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: nil
        )

        #expect(entries.count == 1)
        let body = entries.first?.body ?? ""
        #expect(body.contains("Core"))
        #expect(body.contains("Networking"))
        #expect(body.contains("UI"))
    }

    @Test("Shows dependency arrows")
    func showsDependencyArrows() async throws {
        let tmpDir = try createFixture("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "MyApp",
            targets: [
                .target(name: "Networking", dependencies: ["Core"]),
            ]
        )
        """)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: nil
        )

        let body = entries.first?.body ?? ""
        #expect(body.contains("Networking") && body.contains("Core"))
    }

    @Test("Returns empty when no Package.swift")
    func noPackage() async throws {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir, guidelinesPath: "dg", globalClaudeMD: nil
        )
        #expect(entries.isEmpty)
    }

    private func createFixture(_ packageSwift: String) throws -> String {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try packageSwift.write(toFile: tmpDir + "/Package.swift", atomically: true, encoding: .utf8)
        return tmpDir
    }
}
