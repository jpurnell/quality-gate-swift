import Foundation
import Synchronization
import Testing
import QualityGateCore
@testable import XcodeBuildChecker

/// `xcodebuild` must not be started with the repository git scoped to a hook.
///
/// On 2026-10-06 a push from a linked worktree was refused twice by its own pre-push hook:
///
///     ✗ [xcode-build] FAILED (0ms)
///       ❌ error: Checker failed: Configuration error: xcodebuild -list failed: …
///         xcodebuild: error: Could not resolve package dependencies:
///         Couldn’t check out revision ‘1abee2759f7663b8fcd4d71bb0bcd1ebe6c1677f’:
///
/// git exports `GIT_DIR` to the hooks of a linked worktree. The checker spawned `xcodebuild`
/// inheriting it, and `xcodebuild` resolves packages by running git — against whatever
/// `GIT_DIR` names. The end-to-end reproduction needs a network, an unresolved package and
/// most of a minute, so these tests assert the environment at the seam instead: every
/// launch, not just the first, because any of the three can be the one that resolves.
@Suite("Xcode build: the hook's git scope does not reach xcodebuild")
struct HookEnvironmentTests {

    /// What git 2.55.0 exported to a pre-push hook in a linked worktree, plus a pre-commit
    /// hook's index and a deploy key the user configured.
    private static let hookEnvironment: [String: String] = [
        "GIT_DIR": "/repo/.git/worktrees/feature",
        "GIT_INDEX_FILE": "/repo/.git/worktrees/feature/index",
        "GIT_WORK_TREE": "/repo-feature",
        "GIT_PREFIX": "",
        "GIT_EXEC_PATH": "/opt/homebrew/opt/git/libexec/git-core",
        "GIT_EDITOR": "true",
        "GIT_SSH_COMMAND": "ssh -i ~/.ssh/deploy_key",
        "PATH": "/usr/bin:/bin",
        "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
    ]

    /// A directory holding nothing but a `Package.swift`, which is all discovery looks for.
    private static func makePackageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-hook-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(
            to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        return directory
    }

    /// Answers the three questions the checker asks `xcodebuild`, as a healthy package would.
    private static func healthyAnswer(to invocation: XcodeBuildChecker.Invocation) -> XcodeBuildChecker.ToolOutput {
        if invocation.arguments.contains("-list") {
            return .init(
                stdout: #"{"workspace":{"name":"Probe","schemes":["Probe"]}}"#, stderr: "", exitCode: 0)
        }
        if invocation.arguments.contains("-showBuildSettings") {
            return .init(
                stdout: #"[{"buildSettings":{"SUPPORTED_PLATFORMS":"macosx"}}]"#, stderr: "", exitCode: 0)
        }
        return .init(stdout: "", stderr: "", exitCode: 0)
    }

    @Test("All three launches — list, build settings, build — run without the hook's repository")
    func everyLaunchIsScrubbed() async throws {
        let directory = try Self.makePackageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) } // silent: best-effort cleanup of a temporary fixture

        let launches = Mutex<[XcodeBuildChecker.Invocation]>([])
        let checker = XcodeBuildChecker(
            parentEnvironment: { Self.hookEnvironment },
            launcher: { invocation in
                launches.withLock { $0.append(invocation) }
                return Self.healthyAnswer(to: invocation)
            })

        var configuration = Configuration()
        configuration.projectRoot = directory
        let result = try await checker.check(configuration: configuration)
        let recorded = launches.withLock { $0 }

        #expect(result.status == .passed)
        #expect(recorded.map { $0.arguments.first } == ["-list", "-showBuildSettings", "build"])
        for launch in recorded {
            let what = launch.arguments.first ?? "?"
            for scoped in ["GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "GIT_PREFIX", "GIT_EXEC_PATH"] {
                #expect(launch.environment[scoped] == nil, "\(scoped) reached xcodebuild \(what)")
            }
            #expect(launch.environment["GIT_SSH_COMMAND"] == "ssh -i ~/.ssh/deploy_key")
            #expect(launch.environment["GIT_EDITOR"] == "true")
            #expect(launch.environment["PATH"] == "/usr/bin:/bin")
            #expect(launch.environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
            #expect(launch.environment.count == Self.hookEnvironment.count - 5)
            #expect(launch.directory == directory.path)
        }
    }

    @Test("An environment with no hook in it reaches xcodebuild unchanged")
    func ordinaryEnvironmentIsPassedThrough() {
        let shell = ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "TZ": "UTC"]
        #expect(XcodeBuildChecker.childEnvironment(from: shell) == shell)
    }

    @Test("The checker's rule is the shared one, not a private copy of it")
    func usesTheSharedScrub() {
        #expect(XcodeBuildChecker.childEnvironment(from: Self.hookEnvironment)
                == ChildProcessEnvironment.withoutGitRepositoryScope(Self.hookEnvironment))
    }
}
