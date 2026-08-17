import Foundation
import QualityGateCore
import Testing

/// Phase 1, workstream 4 — the acceptance test, automated.
///
/// Exercises the shipped `quality-gate` binary against a fixture "upstream"
/// repository the way a real contributor would: no repo config, an overlay
/// under an isolated `QUALITY_GATE_HOME`. The assertions ARE the Maintainer's
/// Promise: the upstream tree stays pristine, artifacts land in the overlay,
/// telemetry is silent unless the overlay configures a corpus — and when it
/// does, the record carries the upstream identity plus `identityKind:
/// foreign`.
@Suite("Foreign-mode acceptance", .serialized)
struct ForeignModeAcceptanceTests {

    // MARK: - Harness

    /// Anchor for locating the test bundle (`Bundle(for:)` needs a class).
    private final class BundleToken {}

    /// The built `quality-gate` binary next to the test bundle.
    private static func gateBinary() throws -> URL {
        // The test bundle lives in the products directory; the executable
        // product is its sibling.
        let productsDirectory = Bundle(for: BundleToken.self).bundleURL
            .deletingLastPathComponent()
        let candidate = productsDirectory.appendingPathComponent("quality-gate")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw AcceptanceError.binaryNotFound
        }
        return candidate
    }

    private enum AcceptanceError: Error {
        case binaryNotFound
        case processFailed(String)
    }

    private struct Sandbox {
        let root: URL
        let upstream: URL
        let qgHome: URL
        let corpus: URL

        var overlayDirectory: URL {
            // No git remote in the fixture → identity falls back to the
            // upstream directory's basename.
            qgHome.appendingPathComponent("overlays/upstream")
        }
    }

    /// Builds an isolated sandbox: a committed single-module upstream package
    /// (README but no `.quality-gate.yml`) plus an empty quality-gate home.
    private func makeSandbox() throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreign-acceptance-\(UUID().uuidString)", isDirectory: true)
        let upstream = root.appendingPathComponent("upstream", isDirectory: true)
        let qgHome = root.appendingPathComponent("qg-home", isDirectory: true)
        let corpus = root.appendingPathComponent("corpus", isDirectory: true)
        let sources = upstream.appendingPathComponent("Sources/Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: qgHome, withIntermediateDirectories: true)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Demo",
            targets: [.target(name: "Demo")]
        )
        """.write(to: upstream.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        /// A demo type.
        public struct Demo {
            /// Greets.
            public func greet() -> String { "hello" }
        }
        """.write(to: sources.appendingPathComponent("Demo.swift"), atomically: true, encoding: .utf8)
        try """
        # Demo

        [![CI](https://example.com/badge.svg)](https://example.com)

        An upstream package used to prove
        the foreign-mode read-only guarantee.
        """.write(to: upstream.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        try runGit(["init", "-q"], in: upstream)
        try runGit(["add", "-A"], in: upstream)
        try runGit(["-c", "user.name=acceptance", "-c", "user.email=acceptance@test",
                    "commit", "-qm", "init"], in: upstream)
        return Sandbox(root: root, upstream: upstream, qgHome: qgHome, corpus: corpus)
    }

    private func writeOverlayConfig(_ yaml: String, in sandbox: Sandbox) throws {
        let dir = sandbox.overlayDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try yaml.write(to: dir.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8)
    }

    /// The inherited environment minus every `GIT_*` variable.
    ///
    /// When these tests run inside a git hook (the pre-commit gate runs the
    /// test checker, which runs `swift test`, which runs us), git exports
    /// `GIT_INDEX_FILE`/`GIT_DIR` pointing at the OUTER repository — a
    /// fixture `git add` would then stage fixture paths into the real index
    /// ("invalid object … Error building trees" at commit). Hermetic git,
    /// always.
    private func scrubbedEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let result = try ProcessRunner.run(
            "/usr/bin/git",
            arguments: arguments,
            currentDirectory: directory.path,
            environment: scrubbedEnvironment(),
            mergeStderr: true,
            timeout: 120)
        guard result.exitCode == 0 else {
            throw AcceptanceError.processFailed("git \(arguments.joined(separator: " "))")
        }
    }

    @discardableResult
    private func runGate(
        _ arguments: [String],
        cwd: URL,
        qgHome: URL
    ) throws -> (exitCode: Int32, output: String) {
        var environment = scrubbedEnvironment()
        environment["QUALITY_GATE_HOME"] = qgHome.path
        environment.removeValue(forKey: "QG_FOREIGN_REPO_ROOT")
        // Routed through the bounded runner rather than a hand-rolled Process. This helper spawns
        // the gate itself, whose output far exceeds the ~64 KB pipe buffer, so the old
        // wait-then-read ordering could deadlock — and a hung acceptance test is indistinguishable
        // from the suite simply being slow.
        let result = try ProcessRunner.run(
            try Self.gateBinary().path,
            arguments: arguments,
            currentDirectory: cwd.path,
            environment: environment,
            mergeStderr: true,
            timeout: 300)
        return (result.exitCode, result.stdout)
    }

    private func gitPorcelain(in directory: URL) throws -> String {
        let result = try ProcessRunner.run(
            "/usr/bin/git",
            arguments: ["status", "--porcelain"],
            currentDirectory: directory.path,
            environment: scrubbedEnvironment(),
            timeout: 60)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every file under a directory tree, relative paths, for content asserts.
    /// Both sides resolve symlinks first — `temporaryDirectory` is `/var/…`
    /// but enumerated URLs come back `/private/var/…`.
    private func files(under root: URL) -> [String] {
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var found: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) // silent: unreadable entries just don't count as files
            if values?.isRegularFile == true {
                let path = url.resolvingSymlinksInPath().path
                found.append(path.replacingOccurrences(of: resolvedRoot.path + "/", with: ""))
            }
        }
        return found.sorted()
    }

    // MARK: - The acceptance criteria

    @Test("a foreign sweep leaves the upstream pristine and records foreign-identity telemetry")
    func foreignSweepPristineWithTelemetry() throws {
        let sandbox = try makeSandbox()
        try writeOverlayConfig("""
        legibility:
          useIndexStore: false
        consistency:
          corpusPath: "\(sandbox.corpus.path)"
        """, in: sandbox)

        let run = try runGate(
            ["--check", "legibility", "--no-index-build"],
            cwd: sandbox.upstream, qgHome: sandbox.qgHome)

        #expect(run.exitCode == 0)
        #expect(run.output.contains("Foreign mode"))
        // The Maintainer's Promise, asserted: not one byte in the upstream tree.
        #expect(try gitPorcelain(in: sandbox.upstream) == "")

        // Artifacts landed in the overlay instead.
        let overlayFiles = files(under: sandbox.overlayDirectory)
        #expect(overlayFiles.contains("artifacts/legibility/READING_ORDER.md"))
        #expect(overlayFiles.contains("artifacts/legibility/legibility-map.json"))

        // Telemetry recorded under the upstream identity, marked foreign.
        let corpusFiles = files(under: sandbox.corpus)
        let metadataFiles = corpusFiles.filter { $0.hasSuffix("_metadata.json") }
        #expect(metadataFiles.count == 1)
        let metadataPath = sandbox.corpus.resolvingSymlinksInPath()
            .appendingPathComponent(metadataFiles.first ?? "")
        let metadata = try String(contentsOf: metadataPath, encoding: .utf8)
        #expect(metadata.contains("\"identityKind\" : \"foreign\"")
            || metadata.contains("\"identityKind\":\"foreign\""))
        #expect(metadata.contains("\"upstream\""))
    }

    @Test("foreign runs are silent by default — even a user-global corpus never captures them")
    func foreignSilentByDefault() throws {
        let sandbox = try makeSandbox()
        // Overlay exists (auto-detects foreign) but configures no corpus.
        try writeOverlayConfig("""
        legibility:
          useIndexStore: false
        """, in: sandbox)
        // A user-global corpus path must NOT capture the foreign run.
        try """
        consistency:
          corpusPath: "\(sandbox.corpus.path)"
        """.write(to: sandbox.qgHome.appendingPathComponent("config.yml"),
                  atomically: true, encoding: .utf8)

        let run = try runGate(
            ["--check", "legibility", "--no-index-build"],
            cwd: sandbox.upstream, qgHome: sandbox.qgHome)

        #expect(run.exitCode == 0)
        #expect(run.output.contains("Foreign mode"))
        #expect(FileManager.default.fileExists(atPath: sandbox.corpus.path) == false)
        #expect(try gitPorcelain(in: sandbox.upstream) == "")
    }

    @Test("orient end-to-end: README lead, single-module reading order, watermark")
    func orientEndToEnd() throws {
        let sandbox = try makeSandbox()

        let run = try runGate(
            ["orient", sandbox.upstream.path],
            cwd: sandbox.root, qgHome: sandbox.qgHome)

        #expect(run.exitCode == 0)
        #expect(run.output.contains("# upstream"))
        #expect(run.output.contains(
            "An upstream package used to prove the foreign-mode read-only guarantee."))
        #expect(run.output.contains("1. Demo"))
        #expect(run.output.contains("Role (inferred)"))
        #expect(run.output.contains("does not represent the project's own quality standard"))
        #expect(try gitPorcelain(in: sandbox.upstream) == "")
    }

    @Test("--fix is refused in a foreign run")
    func fixRefused() throws {
        let sandbox = try makeSandbox()
        try writeOverlayConfig("legibility:\n  useIndexStore: false", in: sandbox)

        let run = try runGate(
            ["--check", "legibility", "--no-index-build", "--fix"],
            cwd: sandbox.upstream, qgHome: sandbox.qgHome)

        #expect(run.exitCode == 1)
        #expect(run.output.contains("--fix is refused in foreign mode"))
    }

    @Test("a repo with its own config stays resident: artifacts in its own .build")
    func residentUnaffected() throws {
        let sandbox = try makeSandbox()
        // The repo declares its own config — its standard, its tree.
        try """
        legibility:
          useIndexStore: false
        """.write(to: sandbox.upstream.appendingPathComponent(".quality-gate.yml"),
                  atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: sandbox.upstream)
        try runGit(["-c", "user.name=acceptance", "-c", "user.email=acceptance@test",
                    "commit", "-qm", "own config"], in: sandbox.upstream)
        // An overlay exists too — the repo's own config must still win.
        try writeOverlayConfig("legibility:\n  useIndexStore: false", in: sandbox)

        let run = try runGate(
            ["--check", "legibility", "--no-index-build"],
            cwd: sandbox.upstream, qgHome: sandbox.qgHome)

        #expect(run.exitCode == 0)
        #expect(!run.output.contains("Foreign mode"))
        let readingOrder = sandbox.upstream
            .appendingPathComponent(".build/legibility/READING_ORDER.md")
        #expect(FileManager.default.fileExists(atPath: readingOrder.path))
    }
}
