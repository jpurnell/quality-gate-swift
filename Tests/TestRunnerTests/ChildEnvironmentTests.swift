import Foundation
import Testing
@testable import TestRunner

/// The gate's own control variables must not reach the program it is testing.
///
/// Regression cover for a leak that survived months of local runs and failed on the
/// first clean-checkout CI run: `quality-gate ci` sets `QG_NO_INDEX_BUILD=1` on its
/// own process, `swift test` was spawned inheriting it, and the project's
/// index-backed fixtures then degraded to AST-only inside the test process — seven
/// `UnreachableCodeAuditor` expectations failed with no indication why.
///
/// It needed a *cold* fixture to show: with a warm `.build`, `StoreLocator` finds an
/// existing store and returns before it would have refused to build one. That is why
/// the pre-commit and pre-push hooks could never have caught it.
@Suite("TestRunner: the child environment is not the gate's environment")
struct ChildEnvironmentTests {

    @Test("QG_NO_INDEX_BUILD is stripped from the spawned test process")
    func stripsIndexBuildFlag() {
        let parent = ["QG_NO_INDEX_BUILD": "1", "PATH": "/usr/bin"]
        let child = TestRunner.childEnvironment(from: parent)
        #expect(child["QG_NO_INDEX_BUILD"] == nil)
    }

    @Test("Stripping is unconditional — any value, not just \"1\"")
    func stripsRegardlessOfValue() {
        // StoreLocator only honours "1", but a stale "0" inherited from an outer gate
        // run is still the gate's state leaking into the program under test.
        for value in ["1", "0", "", "true"] {
            let child = TestRunner.childEnvironment(from: ["QG_NO_INDEX_BUILD": value])
            #expect(child["QG_NO_INDEX_BUILD"] == nil, "value \(value) survived")
        }
    }

    @Test("Everything else is passed through untouched")
    func preservesTheRestOfTheEnvironment() {
        let parent = [
            "QG_NO_INDEX_BUILD": "1",
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/someone",
            "TZ": "UTC",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        ]
        let child = TestRunner.childEnvironment(from: parent)

        // The child still needs a working toolchain: scrubbing must be surgical, not
        // a sanitised environment. TZ in particular is a declared CI input.
        #expect(child["PATH"] == "/usr/bin:/bin")
        #expect(child["HOME"] == "/Users/someone")
        #expect(child["TZ"] == "UTC")
        #expect(child["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
        #expect(child.count == parent.count - 1)
    }

    @Test("A hook's repository does not reach the test process, and credentials still do")
    func stripsGitRepositoryScope() {
        // `swift test` resolves dependencies before it builds, by running git. Measured on a
        // package with one unresolved dependency: `GIT_DIR` alone turns `swift build` into
        // `Couldn’t check out revision … fatal: unable to read tree`, and an absolute
        // `GIT_INDEX_FILE` alone lets it exit 0 having overwritten the hooked repository's
        // index with the dependency's files.
        let parent = [
            "GIT_DIR": "/repo/.git/worktrees/feature",
            "GIT_INDEX_FILE": "/repo/.git/worktrees/feature/index",
            "GIT_WORK_TREE": "/repo-feature",
            "GIT_PREFIX": "",
            "GIT_SSH_COMMAND": "ssh -i ~/.ssh/deploy_key",
            "QG_NO_INDEX_BUILD": "1",
            "PATH": "/usr/bin",
        ]
        #expect(TestRunner.childEnvironment(from: parent) == [
            "GIT_SSH_COMMAND": "ssh -i ~/.ssh/deploy_key",
            "PATH": "/usr/bin",
        ])
    }

    @Test("An environment without the flag is unchanged")
    func absentFlagIsANoOp() {
        let parent = ["PATH": "/usr/bin", "HOME": "/Users/someone"]
        #expect(TestRunner.childEnvironment(from: parent) == parent)
    }
}
