import Testing
import Foundation
@testable import DiskCleaner
@testable import QualityGateCore

@Suite("DiskCleaner Tests")
struct DiskCleanerTests {
    @Test("Checker has correct identifier")
    func checkerId() {
        let cleaner = DiskCleaner()
        #expect(cleaner.id == "disk-clean")
    }

    @Test("Checker has correct name")
    func checkerName() {
        let cleaner = DiskCleaner()
        #expect(cleaner.name == "Disk Cleaner")
    }

    @Test("Reports no artifacts when directory is clean")
    func noArtifacts() async throws {
        // Create a temporary clean directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Save current directory and change to temp
        let originalDir = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(tempDir.path)
        defer { FileManager.default.changeCurrentDirectoryPath(originalDir) }

        let cleaner = DiskCleaner()
        let config = Configuration()
        let result = try await cleaner.check(configuration: config)

        #expect(result.status == .passed)
        #expect(result.diagnostics.contains { $0.message == "No build artifacts to clean" })
    }
}
