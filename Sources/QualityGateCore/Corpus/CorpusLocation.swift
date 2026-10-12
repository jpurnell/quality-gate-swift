import Foundation
import QualityGateLogging

/// What git says about whether a path is ignored.
public enum GitIgnoreAnswer: Equatable, Sendable {
    /// An ignore rule covers the path.
    case ignored
    /// The path is inside a working tree and nothing ignores it.
    case notIgnored
    /// git could not say — no repository there, or no git.
    case undetermined
}

/// Asks git whether a path is ignored.
public enum GitIgnoreProbe {

    /// The question, as a function, so resolution can be tested without a repository.
    public typealias Check = @Sendable (_ path: String, _ repositoryRoot: String) -> GitIgnoreAnswer

    private static let logger = Logger(subsystem: "com.quality-gate.core", category: "GitIgnoreProbe")

    /// `git -C <root> check-ignore -q -- <path>`: exit 0 is ignored, 1 is not, anything
    /// else — 128 outside a repository, or git missing — is ``GitIgnoreAnswer/undetermined``.
    public static let check: Check = { path, repositoryRoot in
        let output: ProcessRunner.Output
        do {
            output = try ProcessRunner.run(
                "/usr/bin/git",
                arguments: ["-C", repositoryRoot, "check-ignore", "-q", "--", path],
                environment: GitProvenance.scrubbedGitEnvironment,
                timeout: 30)
        } catch {
            logger.debug(
                "git check-ignore could not run: \(error.localizedDescription, privacy: .public)")
            return .undetermined
        }
        switch output.exitCode {
        case 0: return .ignored
        case 1: return .notIgnored
        default: return .undetermined
        }
    }
}

/// Why a configured corpus path is not a place the gate will read or write.
public enum CorpusLocationProblem: Error, Equatable, Sendable {

    /// The value fails the rule every path-valued key is held to — see ``ConfigPathValue``.
    case invalidValue(ConfigPathProblem)

    /// A relative value that lands inside the repository being checked, unignored.
    ///
    /// The gate writes telemetry on every run. Written here, each run adds untracked files
    /// to the tree it has just judged — the tree is never clean again, and the telemetry
    /// never reaches the corpus anyone reads.
    case insideRepository(value: String, path: String, repositoryRoot: String)

    /// What to print.
    public var message: String {
        switch self {
        case .invalidValue(let problem):
            return problem.message
        case .insideRepository(let value, let path, let repositoryRoot):
            return "`consistency.corpusPath` is set to `\(value)`, which resolves to \(path) "
                + "— inside the repository being checked (\(repositoryRoot)), where git does "
                + "not ignore it. Every run would write telemetry into the working tree as "
                + "untracked files. Point it at the corpus outside this repository, or add it "
                + "to `.gitignore` if a local corpus is intended."
        }
    }
}

/// Where the corpus is — the only way a configured `corpusPath` becomes a location.
///
/// Every reader and writer resolves through here rather than reading
/// `consistency.corpusPath` and handing it to `CorpusPath(basePath:)`, so a value the gate
/// should not act on cannot reach the filesystem from any of them.
public enum CorpusLocation: Equatable, Sendable {

    /// No `consistency.corpusPath`. Not participating; nothing to read or write.
    case unconfigured

    /// An absolute path the gate may use. Whether anything exists there is a separate
    /// question, answered by whoever reads it.
    case usable(path: String)

    /// Configured, and refused. Nothing is read from or written to it.
    case rejected(CorpusLocationProblem)

    /// The key this resolves, as it appears in messages.
    public static let key = "consistency.corpusPath"

    /// Resolves a configured value.
    ///
    /// **Containment applies to relative values only.** An absolute path inside the
    /// repository is something an author wrote out in full and can be taken at their word;
    /// a relative one is how a directory nobody chose comes to exist — the original value
    /// was relative only because nothing expanded it. A relative path that git ignores is
    /// the documented local-corpus setup (`corpusPath: .ijs-corpus`) and stands. Where git
    /// cannot answer there is no working tree to dirty, so the path stands there too.
    ///
    /// This is an error rather than a warning because the alternative is to write: a
    /// warning would be printed beside a run that has already added files to the tree.
    ///
    /// - Parameters:
    ///   - configured: `consistency.corpusPath` as decoded, or `nil` when absent.
    ///   - projectRoot: The repository being checked. Relative values resolve against it.
    ///   - gitIgnore: How to ask git; injectable so this is testable without a repository.
    /// - Returns: The location, or why there is none.
    public static func resolve(
        configured: String?,
        projectRoot: URL,
        gitIgnore: GitIgnoreProbe.Check = GitIgnoreProbe.check
    ) -> CorpusLocation {
        guard let configured else { return .unconfigured }
        if let problem = ConfigPathValue.problem(key: key, value: configured) {
            return .rejected(.invalidValue(problem))
        }
        if configured.hasPrefix("/") {
            return .usable(path: URL(fileURLWithPath: configured).standardizedFileURL.path)
        }

        let root = projectRoot.standardizedFileURL
        let resolved = root.appendingPathComponent(configured).standardizedFileURL
        guard RunEnvironment.path(resolved, isInside: root) else {
            return .usable(path: resolved.path)
        }
        // Asked about a file the gate would write rather than about the directory: a
        // `corpus/` rule does not match a directory that does not exist yet, and the run
        // that matters most is the first one.
        let probe = resolved
            .appendingPathComponent("telemetry")
            .appendingPathComponent("probe.json")
        switch gitIgnore(probe.path, root.path) {
        case .ignored, .undetermined:
            return .usable(path: resolved.path)
        case .notIgnored:
            return .rejected(.insideRepository(
                value: configured, path: resolved.path, repositoryRoot: root.path))
        }
    }
}

extension Configuration {

    /// Where this configuration's corpus is, resolved against its own project root.
    ///
    /// - Parameter gitIgnore: How to ask git whether an in-repository path is ignored.
    /// - Returns: The location every corpus reader and writer should use.
    public func corpusLocation(
        gitIgnore: GitIgnoreProbe.Check = GitIgnoreProbe.check
    ) -> CorpusLocation {
        CorpusLocation.resolve(
            configured: consistency.corpusPath,
            projectRoot: resolvedProjectRoot,
            gitIgnore: gitIgnore)
    }

    /// Everything about this configuration's paths that must stop a run before it starts.
    ///
    /// Every ``pathValueProblems`` entry, then the corpus containment refusal if there is
    /// one. An invalid corpus value is already in the first list and is not repeated.
    ///
    /// - Parameter gitIgnore: How to ask git whether an in-repository path is ignored.
    /// - Returns: One message per problem; empty when the paths can be used as written.
    public func pathConfigurationErrors(
        gitIgnore: GitIgnoreProbe.Check = GitIgnoreProbe.check
    ) -> [String] {
        var messages = pathValueProblems.map(\.message)
        if case .rejected(let problem) = corpusLocation(gitIgnore: gitIgnore),
           case .insideRepository = problem {
            messages.append(problem.message)
        }
        return messages
    }
}

extension CorpusLocation {

    /// The path, when there is one the gate may use.
    public var usablePath: String? {
        if case .usable(let path) = self { return path }
        return nil
    }
}
