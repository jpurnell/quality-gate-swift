import Foundation
import Testing
@testable import QualityGateCore

/// Phase 1, workstream 2 — foreign mode's structural read-only guarantee.
///
/// Every path the gate ever writes resolves through `RunEnvironment`; the
/// `WriteGuard` check is the backstop that turns "we promise not to write
/// into your repo" into a failing test. See the Maintainer's Promise
/// (Phase 1 proposal, Appendix A).
@Suite("RunEnvironment path resolution")
struct RunEnvironmentTests {

    private let repo = URL(fileURLWithPath: "/work/upstream", isDirectory: true)
    private let overlay = URL(fileURLWithPath: "/qg/overlays/acme__widget", isDirectory: true)

    // MARK: - Path resolution

    @Test("resident mode roots artifacts and cache under the repo's .build")
    func residentPaths() {
        let env = RunEnvironment.resident(repoRoot: repo)
        #expect(env.repoRoot == repo)
        #expect(env.isForeign == false)
        #expect(env.artifactsRoot.path == "/work/upstream/.build")
        #expect(env.cacheRoot.path == "/work/upstream/.build")
    }

    @Test("foreign mode redirects every write root into the overlay")
    func foreignPaths() {
        let env = RunEnvironment.foreign(repoRoot: repo, overlayDirectory: overlay)
        #expect(env.repoRoot == repo)
        #expect(env.isForeign == true)
        #expect(env.artifactsRoot.path == "/qg/overlays/acme__widget/artifacts")
        #expect(env.cacheRoot.path == "/qg/overlays/acme__widget/cache")
    }

    // MARK: - WriteGuard

    @Test("resident mode permits writes inside the repo")
    func residentAllowsRepoWrites() {
        let env = RunEnvironment.resident(repoRoot: repo)
        #expect(throws: Never.self) {
            try env.validateWrite(to: repo.appendingPathComponent(".build/legibility/map.json"))
        }
        #expect(throws: Never.self) {
            try env.validateWrite(to: repo.appendingPathComponent("READING_ORDER.md"))
        }
    }

    @Test("foreign mode traps any write inside the analyzed repo")
    func foreignTrapsRepoWrites() {
        let env = RunEnvironment.foreign(repoRoot: repo, overlayDirectory: overlay)
        #expect(throws: QualityGateError.self) {
            try env.validateWrite(to: repo.appendingPathComponent(".quality-gate.yml"))
        }
        #expect(throws: QualityGateError.self) {
            try env.validateWrite(to: repo.appendingPathComponent(".build/legibility/map.json"))
        }
        #expect(throws: QualityGateError.self) {
            try env.validateWrite(to: repo.appendingPathComponent("Sources/Widget/Widget.swift"))
        }
    }

    @Test("foreign mode permits writes to the overlay and elsewhere")
    func foreignAllowsOverlayWrites() {
        let env = RunEnvironment.foreign(repoRoot: repo, overlayDirectory: overlay)
        #expect(throws: Never.self) {
            try env.validateWrite(to: overlay.appendingPathComponent("artifacts/map.json"))
        }
        #expect(throws: Never.self) {
            try env.validateWrite(to: URL(fileURLWithPath: "/tmp/elsewhere.json"))
        }
    }

    @Test("path traversal cannot smuggle a write back into the repo")
    func foreignTrapsTraversal() {
        let env = RunEnvironment.foreign(repoRoot: repo, overlayDirectory: overlay)
        let sneaky = overlay.appendingPathComponent("../../../work/upstream/injected.md")
        #expect(throws: QualityGateError.self) {
            try env.validateWrite(to: sneaky)
        }
    }

    @Test("a repo root prefix match is not enough — sibling dirs are unaffected")
    func siblingDirsAreNotTheRepo() {
        let env = RunEnvironment.foreign(repoRoot: repo, overlayDirectory: overlay)
        // "/work/upstream-notes" shares the string prefix but is a sibling.
        #expect(throws: Never.self) {
            try env.validateWrite(to: URL(fileURLWithPath: "/work/upstream-notes/notes.md"))
        }
    }

    // MARK: - Detection

    @Test("explicit flags always win over auto-detection")
    func explicitFlagsWin() {
        let forcedForeign = RunEnvironment.detect(
            repoRoot: repo, hasRepoConfig: true, overlayDirectory: overlay,
            forceForeign: true, forceResident: false)
        #expect(forcedForeign.isForeign == true)

        let forcedResident = RunEnvironment.detect(
            repoRoot: repo, hasRepoConfig: false, overlayDirectory: overlay,
            forceForeign: false, forceResident: true)
        #expect(forcedResident.isForeign == false)
    }

    @Test("no repo config plus an existing overlay auto-detects foreign")
    func autoDetectForeign() {
        let env = RunEnvironment.detect(
            repoRoot: repo, hasRepoConfig: false, overlayDirectory: overlay,
            forceForeign: false, forceResident: false)
        #expect(env.isForeign == true)
    }

    @Test("a repo with its own config stays resident even when an overlay exists")
    func repoConfigStaysResident() {
        let env = RunEnvironment.detect(
            repoRoot: repo, hasRepoConfig: true, overlayDirectory: overlay,
            forceForeign: false, forceResident: false)
        #expect(env.isForeign == false)
    }

    @Test("no overlay means resident regardless of config")
    func noOverlayStaysResident() {
        let env = RunEnvironment.detect(
            repoRoot: repo, hasRepoConfig: false, overlayDirectory: nil,
            forceForeign: false, forceResident: false)
        #expect(env.isForeign == false)
    }
}

/// The env-var backstop for writers that live below the CLI (artifact
/// emitters, the result cache): the CLI exports `QG_FOREIGN_REPO_ROOT` in
/// foreign mode and every deep writer validates against it before touching
/// disk. Same path semantics as `RunEnvironment.validateWrite`.
@Suite("WriteGuard env backstop")
struct WriteGuardTests {

    @Test("no foreign root in the environment allows everything")
    func inactiveWithoutEnvVar() {
        #expect(throws: Never.self) {
            try WriteGuard.validate(path: "/work/upstream/anything.md", environment: [:])
        }
        #expect(throws: Never.self) {
            try WriteGuard.validate(
                path: "/work/upstream/anything.md",
                environment: [WriteGuard.environmentVariable: ""])
        }
    }

    @Test("a foreign root traps writes under it")
    func trapsUnderForeignRoot() {
        let env = [WriteGuard.environmentVariable: "/work/upstream"]
        #expect(throws: QualityGateError.self) {
            try WriteGuard.validate(path: "/work/upstream/.build/legibility/map.json", environment: env)
        }
        #expect(throws: QualityGateError.self) {
            try WriteGuard.validate(path: "/work/upstream/injected.md", environment: env)
        }
    }

    @Test("a foreign root allows writes outside it")
    func allowsOutsideForeignRoot() {
        let env = [WriteGuard.environmentVariable: "/work/upstream"]
        #expect(throws: Never.self) {
            try WriteGuard.validate(path: "/qg/overlays/acme__widget/artifacts/map.json", environment: env)
        }
        #expect(throws: Never.self) {
            try WriteGuard.validate(path: "/work/upstream-notes/notes.md", environment: env)
        }
    }

    @Test("relative traversal into the foreign root is caught")
    func trapsTraversal() {
        let env = [WriteGuard.environmentVariable: "/work/upstream"]
        #expect(throws: QualityGateError.self) {
            try WriteGuard.validate(path: "/qg/overlays/../../work/upstream/x.md", environment: env)
        }
    }
}
