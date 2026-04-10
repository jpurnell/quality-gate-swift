import Foundation
import Testing
@testable import MemoryBuilder

@Suite("ProjectProfileExtractor")
struct ProjectProfileExtractorTests {

    let extractor = ProjectProfileExtractor()

    @Test("Extracts project name from Package.swift")
    func extractsProjectName() async throws {
        let tmpDir = try createFixtureProject(
            packageSwift: """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "MyAwesomeApp",
                targets: [
                    .target(name: "MyAwesomeApp")
                ]
            )
            """
        )
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir,
            guidelinesPath: "development-guidelines",
            globalClaudeMD: nil
        )

        #expect(entries.count == 1)
        #expect(entries.first?.filename == "project_profile.md")
        #expect(entries.first?.body.contains("MyAwesomeApp") == true)
    }

    @Test("Extracts Swift tools version")
    func extractsToolsVersion() async throws {
        let tmpDir = try createFixtureProject(
            packageSwift: """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "TestProject",
                targets: [
                    .target(name: "TestProject")
                ]
            )
            """
        )
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir,
            guidelinesPath: "development-guidelines",
            globalClaudeMD: nil
        )

        #expect(entries.first?.body.contains("6.0") == true)
    }

    @Test("Extracts target names")
    func extractsTargets() async throws {
        let tmpDir = try createFixtureProject(
            packageSwift: """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "MultiModule",
                targets: [
                    .target(name: "Core"),
                    .target(name: "Networking"),
                    .target(name: "UI"),
                    .testTarget(name: "CoreTests")
                ]
            )
            """
        )
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir,
            guidelinesPath: "development-guidelines",
            globalClaudeMD: nil
        )

        let body = entries.first?.body ?? ""
        #expect(body.contains("Core"))
        #expect(body.contains("Networking"))
        #expect(body.contains("UI"))
    }

    @Test("Extracts dependency names")
    func extractsDependencies() async throws {
        let tmpDir = try createFixtureProject(
            packageSwift: """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "WithDeps",
                dependencies: [
                    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
                    .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
                ],
                targets: [
                    .target(name: "WithDeps")
                ]
            )
            """
        )
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir,
            guidelinesPath: "development-guidelines",
            globalClaudeMD: nil
        )

        let body = entries.first?.body ?? ""
        #expect(body.contains("swift-argument-parser"))
        #expect(body.contains("Yams"))
    }

    @Test("Returns empty when no Package.swift exists")
    func noPackageSwift() async throws {
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

    @Test("Memory entry has correct type")
    func correctType() async throws {
        let tmpDir = try createFixtureProject(
            packageSwift: """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "Test", targets: [.target(name: "Test")])
            """
        )
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let entries = try await extractor.extract(
            projectRoot: tmpDir,
            guidelinesPath: "development-guidelines",
            globalClaudeMD: nil
        )

        #expect(entries.first?.type == "project")
    }

    // MARK: - Helpers

    private func createFixtureProject(packageSwift: String) throws -> String {
        let tmpDir = NSTemporaryDirectory() + "MemoryBuilderTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try packageSwift.write(
            toFile: tmpDir + "/Package.swift",
            atomically: true,
            encoding: .utf8
        )
        return tmpDir
    }
}
