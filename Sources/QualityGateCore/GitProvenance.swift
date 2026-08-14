import Foundation

/// Captures the causal provenance behind a gate run: git commits, `CHANGELOG`
/// delta, and the newest session summary.
///
/// This is the DATA-PLANE half of work-attributed telemetry — it gathers the
/// human context (what commits landed, what the changelog and session notes
/// say) so a metric snapshot can later be joined to *why* it moved.
///
/// ## Graceful degradation
///
/// Provenance is best-effort metadata. A non-git directory, a missing `git`
/// binary, or any subprocess failure yields all-`nil`/empty results and
/// **never** throws — a provenance failure must never fail the gate.
public struct GitProvenance: Sendable {

    /// The provenance captured for a single gate run.
    public struct Result: Sendable, Equatable {
        /// The `HEAD` commit SHA, or `nil` when git is unavailable / not a repo.
        public let headSHA: String?
        /// Subjects of commits new since `sinceSHA` (or recent commits when `sinceSHA` is nil).
        public let subjects: [String]
        /// The top unreleased `CHANGELOG` section text, or `nil` if absent.
        public let changelogDelta: String?
        /// The newest session-summary text, or `nil` if absent.
        public let sessionSummary: String?

        /// Creates a provenance result.
        /// - Parameters:
        ///   - headSHA: The `HEAD` commit SHA, or `nil`.
        ///   - subjects: New commit subjects since the last recorded entry.
        ///   - changelogDelta: Top unreleased `CHANGELOG` section text, or `nil`.
        ///   - sessionSummary: Newest session-summary text, or `nil`.
        public init(
            headSHA: String?,
            subjects: [String],
            changelogDelta: String?,
            sessionSummary: String?
        ) {
            self.headSHA = headSHA
            self.subjects = subjects
            self.changelogDelta = changelogDelta
            self.sessionSummary = sessionSummary
        }
    }

    /// Maximum number of recent commit subjects captured when `sinceSHA` is nil.
    private static let recentSubjectCap = 20
    /// Maximum captured length for the changelog delta and session summary text.
    private static let textCap = 2000

    /// Captures git and document provenance for a repository, best-effort.
    ///
    /// - Parameters:
    ///   - repoPath: The directory being gated (the git repo root, or any path within it).
    ///   - sinceSHA: The last recorded commit SHA; only commits after it are captured.
    ///     When `nil`, up to the most recent 20 subjects are captured.
    /// - Returns: A ``GitProvenance/Result``; all-`nil`/empty on any failure. Never throws.
    public static func capture(repoPath: String, sinceSHA: String?) -> Result {
        let headSHA = runGit(["rev-parse", "HEAD"], in: repoPath)
        let subjects = captureSubjects(repoPath: repoPath, sinceSHA: sinceSHA, headSHA: headSHA)
        let changelogDelta = captureChangelogDelta(repoPath: repoPath)
        let sessionSummary = captureSessionSummary(repoPath: repoPath)
        return Result(
            headSHA: headSHA,
            subjects: subjects,
            changelogDelta: changelogDelta,
            sessionSummary: sessionSummary
        )
    }

    // MARK: - Git

    private static func captureSubjects(repoPath: String, sinceSHA: String?, headSHA: String?) -> [String] {
        // No repo → no subjects.
        guard headSHA != nil else { return [] }

        let range: String
        if let sinceSHA, !sinceSHA.isEmpty {
            range = "\(sinceSHA)..HEAD"
        } else {
            range = "-\(recentSubjectCap)"
        }
        let args = ["log", range, "--format=%s"]
        guard let output = runGit(args, in: repoPath), !output.isEmpty else { return [] }
        return output
            .lines
            .filter { !$0.isEmpty }
    }

    /// The parent environment with `GIT_*` variables removed, so `git -C <path>`
    /// resolves the repository at `<path>` and is not hijacked by an ambient
    /// `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE` — as set when the gate runs
    /// inside a git hook. Without this, provenance would report the hook's repo
    /// rather than the directory actually being gated.
    private static var scrubbedGitEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("GIT_") { env[key] = nil }
        return env
    }

    /// Runs `git -C <repo> <args...>`, returning trimmed stdout on success or `nil` on any failure.
    private static func runGit(_ args: [String], in repoPath: String) -> String? {
        // silent: git provenance is best-effort metadata; git absence must not fail the gate
        guard let output = try? ProcessRunner.run(
            "/usr/bin/git",
            arguments: ["-C", repoPath] + args,
            environment: scrubbedGitEnvironment
        ), output.exitCode == 0 else {
            return nil
        }
        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Documents

    /// Captures the top (unreleased) `CHANGELOG.md` section, if the file exists.
    ///
    /// Returns the text from the first `##` heading up to (but excluding) the
    /// next `##` heading, capped at `textCap` characters. Returns `nil` when
    /// the file is absent or unreadable.
    private static func captureChangelogDelta(repoPath: String) -> String? {
        let path = (repoPath as NSString).appendingPathComponent("CHANGELOG.md")
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // silent: CHANGELOG is best-effort context; an unreadable file yields nil
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        let lines = contents.lines
        var section: [String] = []
        var inSection = false
        for line in lines {
            let isSectionHeading = line.hasPrefix("## ") || line.hasPrefix("##\t")
            if isSectionHeading {
                if inSection { break }
                inSection = true
                section.append(line)
                continue
            }
            if inSection {
                section.append(line)
            }
        }

        let joined = section.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(textCap))
    }

    /// Captures the newest file under `development-guidelines/05_SUMMARIES/`, if present.
    ///
    /// Returns the file's text capped at `textCap` characters, or `nil` when
    /// the directory is absent or empty.
    private static func captureSessionSummary(repoPath: String) -> String? {
        let dir = (repoPath as NSString)
            .appendingPathComponent("development-guidelines/05_SUMMARIES")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        // SAFETY: read-only stat of a fixed guidelines subpath under the gated repo
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return nil }

        // silent: summaries are best-effort context; a listing failure yields nil
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let files = entries.filter { !$0.hasPrefix(".") }
        guard !files.isEmpty else { return nil }

        // Newest by modification date; fall back to name order when dates tie/absent.
        let newest = files
            .map { name -> (name: String, modified: Date) in
                let full = (dir as NSString).appendingPathComponent(name)
                // silent: mtime is best-effort ordering; a stat failure falls back to distantPast
                let attrs = try? fm.attributesOfItem(atPath: full)
                let modified = (attrs?[.modificationDate] as? Date) ?? .distantPast
                return (name, modified)
            }
            .sorted { lhs, rhs in
                if lhs.modified == rhs.modified { return lhs.name > rhs.name }
                return lhs.modified > rhs.modified
            }
            .first

        guard let newest else { return nil }
        let path = (dir as NSString).appendingPathComponent(newest.name)
        // silent: summary text is best-effort context; an unreadable file yields nil
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(textCap))
    }
}
