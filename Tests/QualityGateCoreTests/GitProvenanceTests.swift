import Testing
import Foundation
@testable import QualityGateCore

@Suite("GitProvenance")
struct GitProvenanceTests {

    private func makeTempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitprov-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test("Non-git directory degrades gracefully: nil head, empty subjects, no throw")
    func nonGitDirectory() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = GitProvenance.capture(repoPath: dir, sinceSHA: nil)
        #expect(result.headSHA == nil)
        #expect(result.subjects.isEmpty)
        #expect(result.changelogDelta == nil)
        #expect(result.sessionSummary == nil)
    }

    @Test("Nonexistent path degrades gracefully")
    func nonexistentPath() {
        let result = GitProvenance.capture(
            repoPath: "/nonexistent-\(UUID().uuidString)",
            sinceSHA: nil
        )
        #expect(result.headSHA == nil)
        #expect(result.subjects.isEmpty)
    }

    @Test("Captures HEAD and subjects from a real git repo")
    func realGitRepo() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Best-effort git init + one commit. If git is unavailable, the
        // capture still must not throw; we only assert the graceful contract.
        func git(_ args: [String]) {
            _ = try? ProcessRunner.run("/usr/bin/git", arguments: args, currentDirectory: dir)
        }
        git(["init"])
        git(["config", "user.email", "test@example.com"])
        git(["config", "user.name", "Test"])
        try "hello".write(toFile: dir + "/file.txt", atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-m", "feat: initial commit"])

        let result = GitProvenance.capture(repoPath: dir, sinceSHA: nil)
        // If git actually ran, we expect a head SHA and the subject captured.
        if result.headSHA != nil {
            #expect(result.subjects.contains("feat: initial commit"))
        }
    }

    @Test("Reads CHANGELOG top section when present")
    func changelogPresent() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let changelog = """
        # Changelog

        ## [Unreleased]
        - Added work-attributed telemetry.

        ## [1.0.0]
        - Initial release.
        """
        try changelog.write(toFile: dir + "/CHANGELOG.md", atomically: true, encoding: .utf8)

        let result = GitProvenance.capture(repoPath: dir, sinceSHA: nil)
        #expect(result.changelogDelta?.contains("work-attributed telemetry") == true)
        // Should not bleed into the 1.0.0 section.
        #expect(result.changelogDelta?.contains("Initial release") == false)
    }
}
