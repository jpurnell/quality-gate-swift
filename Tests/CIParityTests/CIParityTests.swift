import Foundation
import QualityGateCore
import Testing

/// Phase 2, workstream 2 — the determinism parity harness.
///
/// The phase's acceptance criterion, automated: a local manual run and a
/// `quality-gate ci` run (under a simulated GitHub Actions environment) of
/// the same fixture must produce **byte-identical diagnostics** after path
/// normalization. Divergent enforcement is worse than absent enforcement;
/// this test is the guarantee that they cannot drift.
@Suite("CI parity", .serialized)
struct CIParityTests {

    private final class BundleToken {}

    private enum ParityError: Error {
        case binaryNotFound
        case processFailed(String)
    }

    private static func gateBinary() throws -> URL {
        let productsDirectory = Bundle(for: BundleToken.self).bundleURL
            .deletingLastPathComponent()
        let candidate = productsDirectory.appendingPathComponent("quality-gate")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw ParityError.binaryNotFound
        }
        return candidate
    }

    /// A fixture whose manifest declares a textual dependency cycle, so the
    /// legibility checker emits real diagnostics — parity over an empty
    /// result set would prove nothing.
    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ci-parity-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        for module in ["Alpha", "Beta"] {
            let dir = root.appendingPathComponent("Sources/\(module)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try """
            /// A fixture type.
            public struct \(module)Type {}
            """.write(to: dir.appendingPathComponent("\(module).swift"), atomically: true, encoding: .utf8)
        }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "ParityFixture",
            targets: [
                .target(name: "Alpha", dependencies: ["Beta"]),
                .target(name: "Beta", dependencies: ["Alpha"]),
            ]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        legibility:
          useIndexStore: false
        """.write(to: root.appendingPathComponent(".quality-gate.yml"), atomically: true, encoding: .utf8)
        return root
    }

    private func scrubbedEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    }

    @discardableResult
    private func runGate(
        _ arguments: [String],
        cwd: URL,
        extraEnvironment: [String: String] = [:]
    ) throws -> Int32 {
        var environment = scrubbedEnvironment()
        environment["TZ"] = "UTC"
        environment.removeValue(forKey: "QG_FOREIGN_REPO_ROOT")
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        let result = try ProcessRunner.run(
            try Self.gateBinary().path,
            arguments: arguments,
            currentDirectory: cwd.path,
            environment: environment,
            mergeStderr: true,
            timeout: 300)
        return result.exitCode
    }

    /// Replaces machine-specific absolute paths so runs from different
    /// checkouts compare equal.
    private func normalized(_ sarif: String, fixtureRoot: URL) -> String {
        sarif
            .replacingOccurrences(of: fixtureRoot.path, with: "$ROOT")
            .replacingOccurrences(of: "/private$ROOT", with: "$ROOT")
    }

    @Test("local run and ci run produce byte-identical diagnostics")
    func localAndCIAreIdentical() throws {
        let fixture = try makeFixture()
        let localSarif = fixture.appendingPathComponent("local-artifacts/quality-gate.sarif")
        let ciDir = fixture.appendingPathComponent("ci-artifacts")

        // Run A — a local manual invocation using the same canonical flags
        // the plan encodes (what a hook or a developer runs).
        let localExit = try runGate([
            "--no-index-build", "--no-cache", "--strict", "--continue-on-failure",
            "--check", "legibility", "complexity",
            "--sarif-output", localSarif.path,
        ], cwd: fixture)

        // Run B — `quality-gate ci` under a simulated GitHub Actions
        // environment (verified identity present, TZ forced by the plan).
        let ciExit = try runGate([
            "ci", "--output-dir", ciDir.path,
            "--checkers", "legibility", "complexity",
        ], cwd: fixture, extraEnvironment: [
            "GITHUB_ACTIONS": "true",
            "GITHUB_ACTOR": "parity-harness",
            "GITHUB_RUN_ID": "1",
            "GITHUB_SHA": "0000000000000000000000000000000000000000",
            "GITHUB_REPOSITORY": "fixture/parity",
        ])

        #expect(localExit == ciExit)

        let localContent = try String(
            contentsOf: localSarif.resolvingSymlinksInPath(), encoding: .utf8)
        let ciContent = try String(
            contentsOf: ciDir.appendingPathComponent("quality-gate.sarif").resolvingSymlinksInPath(),
            encoding: .utf8)

        // The fixture must actually produce findings — empty-vs-empty parity
        // proves nothing. The manifest cycle guarantees at least one.
        #expect(localContent.contains("legibility"))

        let normalizedLocal = normalized(localContent, fixtureRoot: fixture)
        let normalizedCI = normalized(ciContent, fixtureRoot: fixture)
        #expect(normalizedLocal == normalizedCI)
    }

    @Test("two consecutive ci runs are byte-identical (self-determinism)")
    func ciIsSelfDeterministic() throws {
        let fixture = try makeFixture()
        let firstDir = fixture.appendingPathComponent("run-1")
        let secondDir = fixture.appendingPathComponent("run-2")

        for dir in [firstDir, secondDir] {
            let exit = try runGate([
                "ci", "--output-dir", dir.path,
                "--checkers", "legibility", "complexity",
            ], cwd: fixture)
            #expect(exit == 0 || exit == 1)
        }

        let first = try String(
            contentsOf: firstDir.appendingPathComponent("quality-gate.sarif").resolvingSymlinksInPath(),
            encoding: .utf8)
        let second = try String(
            contentsOf: secondDir.appendingPathComponent("quality-gate.sarif").resolvingSymlinksInPath(),
            encoding: .utf8)
        #expect(first == second)
    }
}
