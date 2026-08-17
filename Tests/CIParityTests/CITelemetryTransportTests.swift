import Foundation
import QualityGateCore
import Testing

/// Phase 2 §4 end-to-end — P3a realized: a `quality-gate ci --corpus-remote`
/// run against a local bare "remote" clones the corpus, records telemetry
/// with the provider-verified identity, and pushes it back. No network, no
/// GitHub — the transport is plain git, by design.
@Suite("CI telemetry transport acceptance", .serialized)
struct CITelemetryTransportTests {

    private final class BundleToken {}

    private enum TransportAcceptanceError: Error {
        case binaryNotFound
        case gitFailed(String)
    }

    private static func gateBinary() throws -> URL {
        let productsDirectory = Bundle(for: BundleToken.self).bundleURL
            .deletingLastPathComponent()
        let candidate = productsDirectory.appendingPathComponent("quality-gate")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw TransportAcceptanceError.binaryNotFound
        }
        return candidate
    }

    private func git(_ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("GIT_") }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TransportAcceptanceError.gitFailed(arguments.joined(separator: " "))
        }
    }

    @Test("a ci run pushes verified-identity telemetry to the corpus remote")
    func ciRunPushesTelemetry() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("ci-transport-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()

        // The bare "remote" corpus, seeded with one commit.
        let seed = sandbox.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try "corpus\n".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], cwd: seed)
        try git(["add", "-A"], cwd: seed)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "seed"], cwd: seed)
        let bare = sandbox.appendingPathComponent("remote.git", isDirectory: true)
        try git(["clone", "-q", "--bare", seed.path, bare.path], cwd: sandbox)

        // The analyzed fixture: its config declares projectID but NO corpus
        // path — the remote-cloned corpus is injected by the transport.
        let fixture = sandbox.appendingPathComponent("fixture", isDirectory: true)
        let sources = fixture.appendingPathComponent("Sources/Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Demo", targets: [.target(name: "Demo")])
        """.write(to: fixture.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        /// A demo type.
        public struct Demo {}
        """.write(to: sources.appendingPathComponent("Demo.swift"), atomically: true, encoding: .utf8)
        try """
        legibility:
          useIndexStore: false
        consistency:
          projectID: "transport-fixture"
        """.write(to: fixture.appendingPathComponent(".quality-gate.yml"), atomically: true, encoding: .utf8)

        // Run `ci` with the corpus remote and a simulated GitHub identity.
        var environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("GIT_") }
        environment["GITHUB_ACTIONS"] = "true"
        environment["GITHUB_ACTOR"] = "transport-harness"
        environment["GITHUB_RUN_ID"] = "7"
        environment["GITHUB_SHA"] = "1111111111111111111111111111111111111111"
        environment["GITHUB_REPOSITORY"] = "fixture/transport"
        // The bounded runner: this spawns the gate and pushes to a git remote, so both the pipe
        // buffer and the network are ways for the old wait-then-read ordering to hang the suite.
        let result = try ProcessRunner.run(
            try Self.gateBinary().path,
            arguments: [
                "ci", "--corpus-remote", bare.path,
                "--output-dir", sandbox.appendingPathComponent("artifacts").path,
                "--checkers", "legibility",
            ],
            currentDirectory: fixture.path,
            environment: environment,
            mergeStderr: true,
            timeout: 300)
        let output = result.stdout

        #expect(output.contains("Telemetry pushed to corpus remote"))

        // The proof is in the remote: clone it fresh and find the metadata
        // with the verified identity.
        let verify = sandbox.appendingPathComponent("verify", isDirectory: true)
        try git(["clone", "-q", bare.path, verify.path], cwd: sandbox)
        let telemetryRoot = verify.appendingPathComponent("telemetry/transport-fixture", isDirectory: true)
        let enumerator = FileManager.default.enumerator(atPath: telemetryRoot.path)
        let metadataFiles = (enumerator?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix("_metadata.json") }
        #expect(metadataFiles.count == 1)
        let content = try String(
            contentsOf: telemetryRoot.appendingPathComponent(metadataFiles.first ?? ""),
            encoding: .utf8)
        #expect(content.contains("transport-harness"))
        #expect(content.contains("github-actions"))
    }
}
