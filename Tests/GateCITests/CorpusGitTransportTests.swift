import Foundation
import Testing
@testable import GateCI

/// Phase 2, workstream 3 — the interim git transport for CI telemetry.
///
/// A CI runner has no resident corpus checkout, so `quality-gate ci
/// --corpus-remote <url>` clones the corpus, points telemetry at the clone,
/// and publishes (add/commit/pull --no-rebase/push) after the run.
/// Explicitly interim: the merge noise this accumulates is the measured
/// justification for Phase 3's service. All tests run against local
/// `file://` bare remotes — no network.
@Suite("CorpusGitTransport", .serialized)
struct CorpusGitTransportTests {

    private func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-transport-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A bare "remote" corpus seeded with one commit.
    private func makeBareRemote(in sandbox: URL) throws -> URL {
        let seed = sandbox.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try "corpus\n".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Self.git(["init", "-q", "-b", "main"], cwd: seed)
        try Self.git(["add", "-A"], cwd: seed)
        try Self.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "seed"], cwd: seed)
        let bare = sandbox.appendingPathComponent("remote.git", isDirectory: true)
        try Self.git(["clone", "-q", "--bare", seed.path, bare.path], cwd: sandbox)
        return bare
    }

    private static func git(_ arguments: [String], cwd: URL) throws {
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
            throw TransportTestError.gitFailed(arguments.joined(separator: " "))
        }
    }

    private enum TransportTestError: Error {
        case gitFailed(String)
    }

    @Test("prepare clones the remote and returns a corpus root")
    func prepareClones() throws {
        let sandbox = try makeSandbox()
        let bare = try makeBareRemote(in: sandbox)
        let transport = CorpusGitTransport(
            remote: bare.path,
            workdir: sandbox.appendingPathComponent("work"))

        let corpusRoot = try transport.prepare()
        #expect(FileManager.default.fileExists(
            atPath: corpusRoot.appendingPathComponent("README.md").path))
        #expect(FileManager.default.fileExists(
            atPath: corpusRoot.appendingPathComponent(".git").path))
    }

    @Test("publish pushes new telemetry back to the remote")
    func publishPushes() throws {
        let sandbox = try makeSandbox()
        let bare = try makeBareRemote(in: sandbox)
        let transport = CorpusGitTransport(
            remote: bare.path,
            workdir: sandbox.appendingPathComponent("work"))

        let corpusRoot = try transport.prepare()
        let telemetryDir = corpusRoot.appendingPathComponent("telemetry/fixture/2026-07-10", isDirectory: true)
        try FileManager.default.createDirectory(at: telemetryDir, withIntermediateDirectories: true)
        try "{}".write(to: telemetryDir.appendingPathComponent("120000_metadata.json"),
                       atomically: true, encoding: .utf8)

        try transport.publish(message: "telemetry: fixture run")

        // Verify by cloning the bare remote fresh.
        let verify = sandbox.appendingPathComponent("verify", isDirectory: true)
        try Self.git(["clone", "-q", bare.path, verify.path], cwd: sandbox)
        #expect(FileManager.default.fileExists(
            atPath: verify.appendingPathComponent("telemetry/fixture/2026-07-10/120000_metadata.json").path))
    }

    @Test("publish with nothing new is a no-op, not an error")
    func publishEmptyIsQuiet() throws {
        let sandbox = try makeSandbox()
        let bare = try makeBareRemote(in: sandbox)
        let transport = CorpusGitTransport(
            remote: bare.path,
            workdir: sandbox.appendingPathComponent("work"))
        _ = try transport.prepare()
        #expect(throws: Never.self) {
            try transport.publish(message: "telemetry: nothing")
        }
    }

    @Test("an unreachable remote throws from prepare")
    func unreachableRemoteThrows() throws {
        let sandbox = try makeSandbox()
        let transport = CorpusGitTransport(
            remote: sandbox.appendingPathComponent("does-not-exist.git").path,
            workdir: sandbox.appendingPathComponent("work"))
        #expect(throws: (any Error).self) {
            _ = try transport.prepare()
        }
    }

    @Test("hook-leak variables are scrubbed; credential transport survives")
    func environmentScrubbing() {
        let scrubbed = CorpusGitTransport.scrubbed(environment: [
            "GIT_INDEX_FILE": "/somewhere/.git/index",
            "GIT_DIR": ".git",
            "GIT_WORK_TREE": "/tree",
            "GIT_SSH_COMMAND": "ssh -i /deploy/key",
            "PATH": "/usr/bin",
        ])
        #expect(scrubbed["GIT_INDEX_FILE"] == nil)
        #expect(scrubbed["GIT_DIR"] == nil)
        #expect(scrubbed["GIT_WORK_TREE"] == nil)
        #expect(scrubbed["GIT_SSH_COMMAND"] == "ssh -i /deploy/key")
        #expect(scrubbed["PATH"] == "/usr/bin")
    }
}
