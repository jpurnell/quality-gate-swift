import Foundation
import QualityGateCore

/// Shared git fixture plumbing for the corpusd write-queue tests.
///
/// Every subprocess environment is scrubbed of the hook-leak variables
/// (`GIT_INDEX_FILE`/`GIT_DIR`/`GIT_WORK_TREE`/`GIT_PREFIX`/`GIT_COMMON_DIR`)
/// so a test run inside a commit hook can never stage into the real repo —
/// the shipped `CorpusGitTransport.scrubbed(environment:)` pattern.
enum GitFixture {

    /// A fixture git invocation failure, carrying the combined output.
    struct FixtureError: Error, CustomStringConvertible {
        /// What failed, with git's combined output.
        let description: String
    }

    /// Creates a fresh unique temporary directory and returns its path.
    static func makeTempDir() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-write-queue-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Creates a fresh non-bare git repository and returns its path.
    static func makeRepo() throws -> String {
        let path = try makeTempDir()
        try git(["init", "-q"], cwd: path)
        return path
    }

    /// Runs git in `cwd` with a scrubbed environment, draining the combined
    /// output pipe before waiting (a full ~64 KB pipe buffer would deadlock
    /// against `waitUntilExit()`).
    /// - Returns: The trimmed combined stdout+stderr output.
    /// - Throws: ``FixtureError`` on a nonzero exit.
    @discardableResult
    static func git(_ arguments: [String], cwd: String) throws -> String {
        let result = try ProcessRunner.run(
            "/usr/bin/git",
            arguments: arguments,
            currentDirectory: cwd,
            environment: scrubbed(environment: ProcessInfo.processInfo.environment),
            mergeStderr: true,
            timeout: 120)
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0 else {
            throw FixtureError(
                description: "git \(arguments.joined(separator: " ")) failed: \(output)")
        }
        return output
    }

    /// Removes the hook-leak GIT_* variables from a subprocess environment.
    static func scrubbed(environment: [String: String]) -> [String: String] {
        var scrubbed = environment
        for leaked in ["GIT_INDEX_FILE", "GIT_DIR", "GIT_WORK_TREE", "GIT_PREFIX", "GIT_COMMON_DIR"] {
            scrubbed.removeValue(forKey: leaked)
        }
        return scrubbed
    }
}
