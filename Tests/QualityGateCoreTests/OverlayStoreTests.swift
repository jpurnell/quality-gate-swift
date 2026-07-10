import Foundation
import Testing
@testable import QualityGateCore

/// Phase 1, workstream 1 — the overlay store layout.
///
/// One type owns every path under `~/.quality-gate/` so the resolver, the
/// CLI, and (later) `RunEnvironment` can never disagree about where overlay
/// state lives. Tests pin the layout contract from the Phase 1 proposal:
///
/// ```
/// ~/.quality-gate/
///   config.yml                  # user-global defaults
///   overlays/<identity>/
///     config.yml                # per-project overlay config
///     artifacts/                # redirected artifacts (foreign mode)
///     cache/                    # redirected result cache
/// ```
@Suite("OverlayStore layout")
struct OverlayStoreTests {

    @Test("standard store roots at $HOME/.quality-gate")
    func standardRootFromHome() {
        let store = OverlayStore.standard(environment: ["HOME": "/Users/fixture"])
        #expect(store.root.path == "/Users/fixture/.quality-gate")
    }

    @Test("QUALITY_GATE_HOME overrides the default root")
    func environmentOverride() {
        let store = OverlayStore.standard(environment: [
            "HOME": "/Users/fixture",
            "QUALITY_GATE_HOME": "/tmp/qg-test-home",
        ])
        #expect(store.root.path == "/tmp/qg-test-home")
    }

    @Test("user-global config lives at the store root")
    func userGlobalConfigPath() {
        let store = OverlayStore(root: URL(fileURLWithPath: "/qg"))
        #expect(store.userGlobalConfigURL.path == "/qg/config.yml")
    }

    @Test("overlay paths are keyed by project identity")
    func overlayLayout() {
        let store = OverlayStore(root: URL(fileURLWithPath: "/qg"))
        let identity = "twostraws__ignite"
        #expect(store.overlayDirectory(for: identity).path == "/qg/overlays/twostraws__ignite")
        #expect(store.overlayConfigURL(for: identity).path == "/qg/overlays/twostraws__ignite/config.yml")
        #expect(store.artifactsDirectory(for: identity).path == "/qg/overlays/twostraws__ignite/artifacts")
        #expect(store.cacheDirectory(for: identity).path == "/qg/overlays/twostraws__ignite/cache")
    }

    @Test("identity slugs are sanitized before becoming path components")
    func identitySanitization() {
        let store = OverlayStore(root: URL(fileURLWithPath: "/qg"))
        // A hostile or malformed identity must not escape the overlays dir.
        let dir = store.overlayDirectory(for: "../../etc/passwd")
        #expect(dir.standardizedFileURL.path.hasPrefix("/qg/overlays/"))
        #expect(!dir.standardizedFileURL.path.contains(".."))
    }

    @Test("hasOverlay reflects presence of an overlay config on disk")
    func hasOverlayDetection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-store-\(UUID().uuidString)", isDirectory: true)
        let store = OverlayStore(root: root)
        let identity = "acme__widget"
        #expect(store.hasOverlay(for: identity) == false)

        let configURL = store.overlayConfigURL(for: identity)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "parallelWorkers: 2".write(to: configURL, atomically: true, encoding: .utf8)
        #expect(store.hasOverlay(for: identity) == true)
    }
}
