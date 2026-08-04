import Testing
import Foundation
@testable import DiskCleaner
@testable import QualityGateCore

/// Serialized because `DiskCleaner` resolves its target from the process-global working
/// directory, and these tests move it. Run in parallel they clean each other's fixtures.
@Suite("DiskCleaner Tests", .serialized)
struct DiskCleanerTests {

    /// Runs `body` with the process working directory pointed at a fresh temp dir.
    private static func inTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let originalDir = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(tempDir.path)
        defer { FileManager.default.changeCurrentDirectoryPath(originalDir) }

        return try body(tempDir)
    }

    /// Writes a `.build/` directory holding one file of known size.
    private static func makeBuildDirectory(in root: URL, bytes: Int) throws {
        let buildDir = root.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes)
            .write(to: buildDir.appendingPathComponent("artifact.bin"))
    }

    @Test("Reports no artifacts when directory is clean")
    func noArtifacts() throws {
        let summary = try Self.inTemporaryDirectory { _ in
            DiskCleaner().clean()
        }

        #expect(summary.totalBytesFreed == 0)
        #expect(summary.messages.contains("No build artifacts to clean"))
        #expect(summary.warnings.isEmpty)
    }

    @Test("Removes .build/ and reports the bytes reclaimed")
    func removesBuildDirectory() throws {
        let (summary, buildStillExists) = try Self.inTemporaryDirectory { root in
            try Self.makeBuildDirectory(in: root, bytes: 2048)
            let summary = DiskCleaner().clean()
            let exists = FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".build").path)
            return (summary, exists)
        }

        #expect(summary.totalBytesFreed >= 2048)
        #expect(!buildStillExists)
        #expect(summary.messages.contains { $0.contains("Removed .build/") })
        #expect(summary.wasDryRun == false)
    }

    @Test("A dry run reports what would go and deletes nothing")
    func dryRunRemovesNothing() throws {
        let (summary, buildStillExists) = try Self.inTemporaryDirectory { root in
            try Self.makeBuildDirectory(in: root, bytes: 2048)
            let summary = DiskCleaner().clean(dryRun: true)
            let exists = FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".build").path)
            return (summary, exists)
        }

        #expect(buildStillExists)
        #expect(summary.wasDryRun)
        #expect(summary.totalBytesFreed >= 2048)
        #expect(summary.messages.contains { $0.contains("Would remove .build/") })
    }
}

/// The invariant the `disk-clean` incident was really about: nothing that mutates the
/// working tree may be registered as a checker.
///
/// This used to be enforced by a hardcoded denylist (`CheckerSelection.maintenanceCheckers`)
/// that any future destructive checker would have had to remember to join. Cleanup now
/// lives behind `quality-gate clean` and does not conform to `QualityChecker` at all, so
/// the separation is structural rather than remembered.
@Suite("Checker registry purity")
struct CheckerRegistryPurityTests {

    @Test("DiskCleaner is not a QualityChecker")
    func diskCleanerIsNotAChecker() {
        #expect(!((DiskCleaner() as Any) is any QualityChecker))
    }

    /// `--dry-run` is declared on the root `quality-gate` command, and ArgumentParser
    /// binds parent options before a subcommand's own — so a `--dry-run` flag on `clean`
    /// is shadowed and never set. During development that turned a preview into a 20 GB
    /// deletion. Both spellings must preview.
    @Test("Both --preview and --dry-run request a preview")
    func previewSpellings() {
        #expect(DiskCleaner.wantsPreview(
            previewFlag: true, arguments: ["quality-gate", "clean", "--preview"]))
        #expect(DiskCleaner.wantsPreview(
            previewFlag: false, arguments: ["quality-gate", "clean", "--dry-run"]))
        #expect(DiskCleaner.wantsPreview(
            previewFlag: true, arguments: ["quality-gate", "clean", "--dry-run", "--preview"]))
    }

    @Test("A bare clean invocation is not a preview")
    func bareInvocationDeletes() {
        #expect(!DiskCleaner.wantsPreview(
            previewFlag: false, arguments: ["quality-gate", "clean"]))
        #expect(!DiskCleaner.wantsPreview(
            previewFlag: false, arguments: ["quality-gate", "clean", "--gc"]))
    }

    @Test("Selection no longer carries a destructive-checker denylist")
    func noMaintenanceDenylist() {
        // `--check all` returns every id it is given; nothing is silently withheld.
        let ids = ["safety", "recursion", "concurrency"]
        let resolved = CheckerSelection.resolve(
            requested: ["all"], excluded: [], configuredEnabled: [], full: false, allIDs: ids)
        #expect(resolved == ids)
    }
}
