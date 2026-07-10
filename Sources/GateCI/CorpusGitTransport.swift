import Foundation

/// The interim git transport for CI telemetry (Phase 2 §4).
///
/// A CI runner has no resident corpus checkout: `prepare()` clones the
/// corpus remote into a working directory, the run writes telemetry into
/// the clone, and `publish(message:)` lands it (add → commit → pull
/// --no-rebase → push, the same merge strategy the pulse pipeline uses).
///
/// **Explicitly interim**: replaced by the Phase 3 service. The corpus
/// receives multi-writer traffic through this transport *before* Phase 3,
/// deliberately — the merge noise accumulated here is the measured
/// justification for the service, not a hypothetical.
public struct CorpusGitTransport: Sendable {
    /// The corpus git remote (URL or path).
    public let remote: String
    /// Directory the corpus is cloned into.
    public let workdir: URL

    /// Creates a transport.
    /// - Parameters:
    ///   - remote: The corpus git remote (any form git accepts).
    ///   - workdir: Clone destination; created if missing.
    public init(remote: String, workdir: URL) {
        self.remote = remote
        self.workdir = workdir
    }

    /// A transport error with the failing git invocation's output.
    public struct TransportError: Error, CustomStringConvertible {
        /// What failed, with git's combined output.
        public let description: String
    }

    /// Clones the corpus (reusing an existing clone in `workdir` if present)
    /// and returns the corpus root suitable for `--telemetry-corpus-path`.
    ///
    /// - Returns: The clone's root directory.
    /// - Throws: ``TransportError`` when the remote is unreachable.
    public func prepare() throws -> URL {
        if FileManager.default.fileExists(atPath: workdir.appendingPathComponent(".git").path) {
            try run(["pull", "--no-rebase", "-q"], cwd: workdir)
            return workdir
        }
        try FileManager.default.createDirectory(
            at: workdir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run(["clone", "-q", remote, workdir.path],
                cwd: workdir.deletingLastPathComponent())
        return workdir
    }

    /// Publishes everything new in the clone: add → commit → pull
    /// --no-rebase → push. A clean tree is a quiet no-op.
    ///
    /// - Parameter message: The telemetry commit message.
    /// - Throws: ``TransportError`` when the push cannot land.
    public func publish(message: String) throws {
        try run(["add", "-A"], cwd: workdir)
        guard try hasStagedChanges() else { return }
        try run([
            "-c", "user.name=quality-gate-ci",
            "-c", "user.email=ci@quality-gate.invalid",
            "commit", "-qm", message,
        ], cwd: workdir)
        try run(["pull", "--no-rebase", "-q"], cwd: workdir)
        try run(["push", "-q"], cwd: workdir)
    }

    /// Whether the clone's index holds anything to commit.
    private func hasStagedChanges() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--cached", "--quiet"]
        process.currentDirectoryURL = workdir
        process.environment = Self.scrubbed(environment: ProcessInfo.processInfo.environment)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        // git diff --quiet: exit 1 means differences exist.
        return process.terminationStatus == 1
    }

    /// The environment for spawned git: hook-leak variables removed
    /// (GIT_INDEX_FILE/GIT_DIR/GIT_WORK_TREE point at the *hooked* repo when
    /// running inside a commit hook — the Phase 1 war story), credential
    /// transport (GIT_SSH_COMMAND, deploy keys) preserved.
    static func scrubbed(environment: [String: String]) -> [String: String] {
        var scrubbed = environment
        for leaked in ["GIT_INDEX_FILE", "GIT_DIR", "GIT_WORK_TREE", "GIT_PREFIX", "GIT_COMMON_DIR"] {
            scrubbed.removeValue(forKey: leaked)
        }
        return scrubbed
    }

    /// Runs git, throwing with combined output on a nonzero exit.
    private func run(_ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = Self.scrubbed(environment: ProcessInfo.processInfo.environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain the pipe before waiting: a full pipe buffer (~64 KB) would
        // deadlock a chatty git invocation against waitUntilExit().
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: outputData, as: UTF8.self)
            throw TransportError(
                description: "git \(arguments.joined(separator: " ")) failed: \(output)")
        }
    }
}
