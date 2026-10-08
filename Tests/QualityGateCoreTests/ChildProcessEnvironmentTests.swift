import Foundation
import Testing
@testable import QualityGateCore

/// A build tool the gate launches must not inherit the repository git handed to a hook.
///
/// Regression cover for two refused pushes on 2026-10-06. The pre-push hook of a linked
/// worktree ran `quality-gate --check all`; git had exported `GIT_DIR` pointing at the main
/// repository's `worktrees/<name>`; `xcode-build` spawned `xcodebuild` inheriting it; and
/// `xcodebuild`'s package resolution — which shells out to git to clone and check out each
/// dependency — ran every one of those commands against the *hooked* repository:
///
///     xcodebuild: error: Could not resolve package dependencies:
///       Couldn’t check out revision ‘1abee2759f7663b8fcd4d71bb0bcd1ebe6c1677f’:
///
/// The same checker passed when run by hand minutes later, because a shell has no `GIT_DIR`.
@Suite("ChildProcessEnvironment: git's hook scope does not reach a child")
struct ChildProcessEnvironmentTests {

    /// What `env | grep ^GIT_` printed inside a pre-commit hook of a linked worktree
    /// (git 2.55.0), plus the variables a user sets on purpose.
    private static let hookShaped: [String: String] = [
        "GIT_DIR": "/repo/.git/worktrees/feature",
        "GIT_INDEX_FILE": "/repo/.git/worktrees/feature/index",
        "GIT_PREFIX": "",
        "GIT_EXEC_PATH": "/opt/homebrew/opt/git/libexec/git-core",
        "GIT_EDITOR": ":",
        "GIT_AUTHOR_NAME": "A Developer",
        "GIT_AUTHOR_EMAIL": "dev@example.invalid",
        "GIT_AUTHOR_DATE": "@1791469382 -0400",
        "GIT_SSH_COMMAND": "ssh -i ~/.ssh/deploy_key",
        "GIT_ASKPASS": "/usr/local/bin/askpass",
        "PATH": "/usr/bin:/bin",
        "HOME": "/Users/someone",
    ]

    // MARK: - Removed

    @Test("The variables the hook reproduction captured are removed",
          arguments: ["GIT_DIR", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_EXEC_PATH"])
    func removesWhatAHookSets(name: String) {
        let child = ChildProcessEnvironment.withoutGitRepositoryScope(Self.hookShaped)
        #expect(child[name] == nil, "\(name) reached the child")
    }

    @Test("Every repository-scoped variable is removed, whatever its value",
          arguments: [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR",
            "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_QUARANTINE_PATH",
            "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE", "GIT_SHALLOW_FILE",
            "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_EXEC_PATH",
          ])
    func removesEveryRepositoryScopedVariable(name: String) {
        for value in ["/somewhere", "", "1"] {
            let child = ChildProcessEnvironment.withoutGitRepositoryScope([name: value, "PATH": "/usr/bin"])
            #expect(child == ["PATH": "/usr/bin"], "\(name)=\(value) reached the child")
        }
    }

    @Test("The removal list is exactly the documented fourteen")
    func removalListIsPinned() {
        // Pinned so that widening it is a decision someone makes in a diff, not a side
        // effect: every name added here is a variable some user can no longer pass through
        // the gate to their build.
        #expect(ChildProcessEnvironment.repositoryScopedGitVariables.sorted() == [
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_DIR", "GIT_EXEC_PATH",
            "GIT_GRAFT_FILE", "GIT_IMPLICIT_WORK_TREE", "GIT_INDEX_FILE",
            "GIT_NO_REPLACE_OBJECTS", "GIT_OBJECT_DIRECTORY", "GIT_PREFIX",
            "GIT_QUARANTINE_PATH", "GIT_REPLACE_REF_BASE", "GIT_SHALLOW_FILE", "GIT_WORK_TREE",
        ])
    }

    // MARK: - Kept

    @Test("What a user sets on purpose still reaches the child",
          arguments: [
            "GIT_SSH_COMMAND", "GIT_SSH", "GIT_ASKPASS", "SSH_ASKPASS", "GIT_TERMINAL_PROMPT",
            "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_CONFIG_PARAMETERS",
            "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG",
            "GIT_AUTHOR_NAME", "GIT_COMMITTER_EMAIL", "GIT_EDITOR", "GIT_TRACE",
            "GIT_SSL_CAINFO", "GIT_HTTP_USER_AGENT", "SSH_AUTH_SOCK",
          ])
    func keepsDeliberateSettings(name: String) {
        // A private dependency is fetched with exactly these. Stripping every `GIT_*`
        // would trade "could not check out revision" for "could not authenticate".
        let parent = [name: "value", "GIT_DIR": "/repo/.git"]
        let child = ChildProcessEnvironment.withoutGitRepositoryScope(parent)
        #expect(child == [name: "value"])
    }

    @Test("A hook-shaped environment loses the four scoped variables and nothing else")
    func hookShapedEnvironmentIsScrubbedSurgically() {
        let child = ChildProcessEnvironment.withoutGitRepositoryScope(Self.hookShaped)
        var expected = Self.hookShaped
        for name in ["GIT_DIR", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_EXEC_PATH"] {
            expected.removeValue(forKey: name)
        }
        #expect(child == expected)
        #expect(child.count == Self.hookShaped.count - 4)
    }

    @Test("An ordinary environment is unchanged")
    func ordinaryEnvironmentIsUnchanged() {
        let parent = ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "TZ": "UTC"]
        #expect(ChildProcessEnvironment.withoutGitRepositoryScope(parent) == parent)
    }

    @Test("An empty environment stays empty")
    func emptyEnvironmentStaysEmpty() {
        #expect(ChildProcessEnvironment.withoutGitRepositoryScope([:]) == [:])
    }

    @Test("A variable that merely resembles a scoped one is kept")
    func nearMissesAreKept() {
        let parent = ["GIT_DIRECTORY": "x", "MY_GIT_DIR": "y", "git_dir": "z"]
        #expect(ChildProcessEnvironment.withoutGitRepositoryScope(parent) == parent)
    }

    // MARK: - Against real git

    /// Two repositories: the one a hook would name, and the one a tool is working in.
    private struct TwoRepositories {
        let root: URL
        let hooked: URL
        let audited: URL
        let auditedHead: String

        /// An environment in which nothing ambient can name a repository.
        static var neutral: [String: String] {
            var environment = ProcessInfo.processInfo.environment
            for key in environment.keys where key.hasPrefix("GIT_") { environment[key] = nil }
            return environment
        }

        static func git(
            _ arguments: [String], in directory: URL, environment: [String: String]
        ) throws -> ProcessRunner.Output {
            try ProcessRunner.run(
                "/usr/bin/git", arguments: arguments, currentDirectory: directory.path,
                environment: environment, timeout: 60)
        }

        /// Creates a one-commit repository at `directory` and returns its HEAD.
        private static func makeRepository(at directory: URL, named name: String) throws -> String {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "\(name)\n".write(
                to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            for arguments in [
                ["init", "-q", "-b", "main"],
                ["add", "-A"],
                ["-c", "user.name=t", "-c", "user.email=t@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", name],
            ] {
                let result = try git(arguments, in: directory, environment: neutral)
                try #require(result.exitCode == 0, "git \(arguments) failed: \(result.stderr)")
            }
            return try git(["rev-parse", "HEAD"], in: directory, environment: neutral)
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func make() throws -> TwoRepositories {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("child-env-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            let hooked = root.appendingPathComponent("hooked")
            let audited = root.appendingPathComponent("audited")
            _ = try makeRepository(at: hooked, named: "hooked")
            let auditedHead = try makeRepository(at: audited, named: "audited")
            return TwoRepositories(root: root, hooked: hooked, audited: audited, auditedHead: auditedHead)
        }

        /// What git exports to a hook of `hooked`, laid over a neutral environment.
        var hookEnvironment: [String: String] {
            var environment = Self.neutral
            environment["GIT_DIR"] = hooked.appendingPathComponent(".git").path
            environment["GIT_INDEX_FILE"] = hooked.appendingPathComponent(".git/index").path
            environment["GIT_PREFIX"] = ""
            return environment
        }
    }

    @Test("git run in the audited directory sees the audited repository, not the hook's")
    func gitResolvesTheRepositoryItIsRunIn() throws {
        let fixture = try TwoRepositories.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) } // silent: best-effort cleanup of a temporary fixture

        let scrubbed = ChildProcessEnvironment.withoutGitRepositoryScope(fixture.hookEnvironment)
        let head = try TwoRepositories.git(["rev-parse", "HEAD"], in: fixture.audited, environment: scrubbed)

        #expect(head.exitCode == 0)
        #expect(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == fixture.auditedHead)
    }

    @Test("A dependency checkout — what a package manager does — succeeds under a hook's environment")
    func dependencyCheckoutSucceedsUnderAHookEnvironment() throws {
        let fixture = try TwoRepositories.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) } // silent: best-effort cleanup of a temporary fixture

        // The two commands SwiftPM and xcodebuild run per dependency: clone the cached
        // repository without a working copy, then check a pinned revision out of it.
        let checkout = fixture.root.appendingPathComponent("checkouts/dependency")
        let scrubbed = ChildProcessEnvironment.withoutGitRepositoryScope(fixture.hookEnvironment)

        let clone = try TwoRepositories.git(
            ["clone", "-q", "--no-checkout", fixture.audited.path, checkout.path],
            in: fixture.root, environment: scrubbed)
        try #require(clone.exitCode == 0, "clone failed: \(clone.stderr)")
        let pinned = try TwoRepositories.git(
            ["-C", checkout.path, "checkout", "-q", "-f", fixture.auditedHead],
            in: fixture.root, environment: scrubbed)

        #expect(pinned.exitCode == 0, "checkout failed: \(pinned.stderr)")
        #expect(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("audited.txt").path))
    }

    @Test("The fixture reproduces the failure: unscrubbed, the same checkout cannot find its revision")
    func unscrubbedCheckoutFailsTheWayThePushDid() throws {
        // The control. Without it the test above could pass for a reason unrelated to the
        // scrubbing — a git that ignores GIT_DIR under `-C`, say — and nobody would know.
        let fixture = try TwoRepositories.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) } // silent: best-effort cleanup of a temporary fixture

        let checkout = fixture.root.appendingPathComponent("checkouts/dependency")
        let clone = try TwoRepositories.git(
            ["clone", "-q", "--no-checkout", fixture.audited.path, checkout.path],
            in: fixture.root, environment: TwoRepositories.neutral)
        try #require(clone.exitCode == 0, "clone failed: \(clone.stderr)")

        let pinned = try TwoRepositories.git(
            ["-C", checkout.path, "checkout", "-q", "-f", fixture.auditedHead],
            in: fixture.root, environment: fixture.hookEnvironment)

        // 128 is git's `fatal:`; the message is the one SwiftPM and xcodebuild relayed.
        #expect(pinned.exitCode == 128)
        #expect(pinned.stderr.contains("unable to read tree (\(fixture.auditedHead))"))
    }
}
