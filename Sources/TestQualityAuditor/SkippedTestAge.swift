import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// How long a skipped test has been sitting there, read from `git blame`.
///
/// ## This number is reported and never enforced
///
/// The proposal this rule comes from asked for an escalation: `error` once a disabled test
/// passed 180 days. That was rejected before any of it was written, and the reasoning is
/// worth keeping next to the code it shaped.
///
/// ``TestQualityAuditor/cacheInputs(configuration:)`` declares this checker a pure function
/// of the source tree — "no clock, corpus, network or out-of-tree path among its inputs."
/// An age threshold adds a clock *and* an out-of-tree path, and two things break. The
/// verdict stops being a property of the commit: a tree that passes in September fails in
/// March with no edit, and a developer cannot reproduce a failure whose cause is not in the
/// diff. And the cache answers wrongly across the boundary: cache keys hash the source tree,
/// so on the day a test crosses the threshold nothing has changed, the entry is still live,
/// and the escalation fires later — on whichever unrelated commit happens to miss the cache.
///
/// So the age is *shown*, which was the actual goal: a six-month-old disabled test is
/// visible on every run and cannot rot quietly. It never changes a severity and never
/// reaches a cache key.
///
/// ## Best effort, by construction
///
/// Every failure path returns `nil` and the diagnostic simply omits the age. A shallow
/// clone, a source export, a tarball, a file staged but never committed, a machine with no
/// `git` — each is a normal way to run the gate, and none of them is a reason to fail a
/// test-quality check or to make its output depend on how the tree arrived.
enum SkippedTestAge {

    private static let logger = Logger(
        subsystem: "com.quality-gate", category: "SkippedTestAge")

    /// Whole days since the last commit that touched a line, or `nil` if unknowable.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the file.
    ///   - line: 1-indexed line number.
    ///   - now: The clock, injected so the unit tests are not themselves time-dependent.
    /// - Returns: Days since that line was last written, or `nil`.
    static func days(path: String, line: Int, now: Date = Date()) -> Int? {
        guard line >= 1 else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return nil }

        guard let output = runGit(
            ["blame", "-L", "\(line),\(line)", "--porcelain", "--", path],
            in: directory
        ) else { return nil }

        // Porcelain format puts `author-time <epoch>` on its own line.
        guard let field = output.lines.first(where: { $0.hasPrefix("author-time ") }) else {
            return nil
        }
        let epochText = field.dropFirst("author-time ".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let epoch = TimeInterval(epochText) else { return nil }

        let written = Date(timeIntervalSince1970: epoch)
        let seconds = now.timeIntervalSince(written)
        guard seconds >= 0 else { return nil }
        return Int(seconds / 86_400)
    }

    /// The parent environment with `GIT_*` removed.
    ///
    /// The gate runs inside a pre-commit hook, which exports `GIT_DIR` and `GIT_INDEX_FILE`.
    /// Without scrubbing them, `git -C <dir>` reports the hook's repository rather than the
    /// directory being gated — the same hazard `GitProvenance` documents.
    private static var scrubbedGitEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment[key] = nil }
        return environment
    }

    /// Runs `git -C <directory> <args…>`, returning trimmed stdout or `nil` on any failure.
    private static func runGit(_ arguments: [String], in directory: String) -> String? {
        let output: ProcessRunner.Output
        do {
            output = try ProcessRunner.run(
                "/usr/bin/git",
                arguments: ["-C", directory] + arguments,
                environment: scrubbedGitEnvironment,
                timeout: 10)
        } catch {
            // Debug, not warning: an absent git and a non-repository are both documented,
            // expected outcomes here. Logged anyway so "no ages at all" has a cause.
            logger.debug(
                "skipped-test age unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard output.exitCode == 0 else { return nil }
        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
