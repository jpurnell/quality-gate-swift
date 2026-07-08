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

    @Test("Existing directory with no docs has no document provenance, no throw")
    func emptyDirectoryHasNoDocProvenance() {
        // An existing, empty directory has no CHANGELOG.md and no
        // development-guidelines/05_SUMMARIES, so the document fields are nil.
        // headSHA/subjects are intentionally NOT asserted here: under a sandboxed
        // test runner, $TMPDIR can resolve *inside* an enclosing repo, so git may
        // report that repo's HEAD — an ambient-dependent value that would make
        // this test flip. The "no repo → nil head, empty subjects" contract is
        // covered deterministically by `nonexistentPath`, whose path cannot sit
        // inside any repo.
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = GitProvenance.capture(repoPath: dir, sinceSHA: nil)
        #expect(result.changelogDelta == nil)
        #expect(result.sessionSummary == nil)
    }

    @Test("Nonexistent path degrades gracefully: nil head, empty subjects, nil docs")
    func nonexistentPath() {
        // A path that does not exist cannot sit inside any git repo, so this
        // deterministically exercises the full graceful-degradation contract.
        let result = GitProvenance.capture(
            repoPath: "/nonexistent-\(UUID().uuidString)",
            sinceSHA: nil
        )
        #expect(result.headSHA == nil)
        #expect(result.subjects.isEmpty)
        #expect(result.changelogDelta == nil)
        #expect(result.sessionSummary == nil)
    }

    @Test("Captures HEAD and subjects from a real git repo")
    func realGitRepo() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Best-effort git init + one commit. If git is unavailable, the
        // capture still must not throw; we only assert the graceful contract.
        //
        // CRITICAL: scrub inherited GIT_* vars. When the quality gate runs as a
        // pre-commit hook, git exports GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE; a
        // child `git commit` that inherits them lands in the HOST repository, not
        // `dir`. Scrubbing GIT_* (plus `-C dir`) keeps these commands isolated.
        var gitEnv = ProcessInfo.processInfo.environment
        for key in gitEnv.keys where key.hasPrefix("GIT_") { gitEnv[key] = nil }
        func git(_ args: [String]) {
            _ = try? ProcessRunner.run(
                "/usr/bin/git",
                arguments: ["-C", dir] + args,
                currentDirectory: dir,
                environment: gitEnv
            )
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
