import Testing
import QualityGateCore
@testable import BuildChecker

/// `swift build` must not be started with the repository git scoped to a hook.
///
/// `swift build` resolves package dependencies by running git, exactly as `xcodebuild`
/// does, and fails the same way: in a scratch package with one unresolved dependency,
/// `GIT_DIR=<hooked repository> swift build` ends in
///
///     error: 'swift-numerics': Couldn’t check out revision ‘0c0290ff…’:
///         fatal: unable to read tree (0c0290ff…)
///
/// The `build` checker never showed it only because by the time a hook ran, something had
/// usually resolved `.build` already. `xcode-build` resolves into DerivedData, which a new
/// worktree does not have — so it was the one that reported the leak both share.
@Suite("BuildChecker: the hook's git scope does not reach swift build")
struct BuildChildEnvironmentTests {

    @Test("A hook's repository is removed and everything else is kept")
    func stripsGitRepositoryScope() {
        let parent = [
            "GIT_DIR": "/repo/.git/worktrees/feature",
            "GIT_INDEX_FILE": "/repo/.git/worktrees/feature/index",
            "GIT_WORK_TREE": "/repo-feature",
            "GIT_PREFIX": "",
            "GIT_EXEC_PATH": "/opt/homebrew/opt/git/libexec/git-core",
            "GIT_SSH_COMMAND": "ssh -i ~/.ssh/deploy_key",
            "GIT_CONFIG_COUNT": "1",
            "PATH": "/usr/bin",
        ]
        #expect(BuildChecker.childEnvironment(from: parent) == [
            "GIT_SSH_COMMAND": "ssh -i ~/.ssh/deploy_key",
            "GIT_CONFIG_COUNT": "1",
            "PATH": "/usr/bin",
        ])
    }

    @Test("An ordinary environment is unchanged")
    func ordinaryEnvironmentIsUnchanged() {
        let parent = ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "TZ": "UTC"]
        #expect(BuildChecker.childEnvironment(from: parent) == parent)
    }

    @Test("The rule is the shared one, not a private copy of it")
    func usesTheSharedScrub() {
        let parent = ["GIT_DIR": "/repo/.git", "GIT_OBJECT_DIRECTORY": "/repo/.git/objects", "TZ": "UTC"]
        #expect(BuildChecker.childEnvironment(from: parent)
                == ChildProcessEnvironment.withoutGitRepositoryScope(parent))
    }
}
