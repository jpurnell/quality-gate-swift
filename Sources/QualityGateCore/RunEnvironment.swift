import Foundation

/// Where a gate run is allowed to write (Phase 1).
///
/// Resident runs (the repo is yours) behave as they always have: artifacts
/// and caches live under the repo's `.build`. Foreign runs (analyzing a repo
/// you don't own) redirect **every** write into the overlay directory, and
/// ``validateWrite(to:)`` is the structural backstop behind the Maintainer's
/// Promise: an attempted in-repo write is an error, not a code review find.
public enum RunEnvironment: Sendable, Equatable {
    /// Today's behavior — the analyzed repo is the writer's own.
    case resident(repoRoot: URL)
    /// Foreign analysis — all writes land in the overlay directory.
    case foreign(repoRoot: URL, overlayDirectory: URL)

    /// Root of the repository being analyzed.
    public var repoRoot: URL {
        switch self {
        case .resident(let root), .foreign(let root, _):
            return root
        }
    }

    /// Whether this run must not write into the analyzed repo.
    public var isForeign: Bool {
        if case .foreign = self { return true }
        return false
    }

    /// Base directory for gate-generated artifacts (legibility maps,
    /// reading orders, orientation reports).
    public var artifactsRoot: URL {
        switch self {
        case .resident(let root):
            return root.appendingPathComponent(".build", isDirectory: true)
        case .foreign(_, let overlay):
            return overlay.appendingPathComponent("artifacts", isDirectory: true)
        }
    }

    /// Base directory for the incremental result cache.
    public var cacheRoot: URL {
        switch self {
        case .resident(let root):
            return root.appendingPathComponent(".build", isDirectory: true)
        case .foreign(_, let overlay):
            return overlay.appendingPathComponent("cache", isDirectory: true)
        }
    }

    /// The WriteGuard — confirms a proposed write is legal for this run.
    ///
    /// Resident runs allow everything. Foreign runs reject any destination
    /// inside the analyzed repo, path-traversal included: both sides are
    /// standardized before comparison and matched on whole path components,
    /// so `overlay/../repo` is caught and `/work/upstream-notes` is not
    /// mistaken for `/work/upstream`.
    ///
    /// - Parameter url: The write destination a caller is about to use.
    /// - Throws: ``QualityGateError/writeGuardViolation(path:)`` when a
    ///   foreign run attempts an in-repo write.
    public func validateWrite(to url: URL) throws {
        guard case .foreign(let root, _) = self else { return }
        if Self.path(url, isInside: root) {
            throw QualityGateError.writeGuardViolation(path: url.standardizedFileURL.path)
        }
    }

    /// Whole-component containment check shared with ``WriteGuard`` and the
    /// CLI's output-path validation: standardizes both sides (so `..`
    /// traversal is resolved) and matches on path components, so a sibling
    /// like `/work/upstream-notes` is never mistaken for `/work/upstream`.
    public static func path(_ url: URL, isInside root: URL) -> Bool {
        let target = url.standardizedFileURL.pathComponents
        let repo = root.standardizedFileURL.pathComponents
        return target.count >= repo.count && Array(target.prefix(repo.count)) == repo
    }

    /// Chooses the environment for a run.
    ///
    /// Explicit flags always win. Otherwise a repo with no config of its own
    /// **and** an existing overlay is foreign; everything else is resident.
    /// Forcing foreign without an overlay directory falls back to resident —
    /// there is nowhere to redirect writes to.
    ///
    /// - Parameters:
    ///   - repoRoot: Root of the repository being analyzed.
    ///   - hasRepoConfig: Whether the repo declares its own `.quality-gate.yml`.
    ///   - overlayDirectory: This project's overlay directory, if the caller
    ///     resolved one whose config exists on disk.
    ///   - forceForeign: The `--foreign` CLI flag.
    ///   - forceResident: The `--resident` CLI flag.
    /// - Returns: The environment every writer should resolve paths through.
    public static func detect(
        repoRoot: URL,
        hasRepoConfig: Bool,
        overlayDirectory: URL?,
        forceForeign: Bool,
        forceResident: Bool
    ) -> RunEnvironment {
        if forceResident {
            return .resident(repoRoot: repoRoot)
        }
        if let overlay = overlayDirectory, forceForeign || !hasRepoConfig {
            return .foreign(repoRoot: repoRoot, overlayDirectory: overlay)
        }
        return .resident(repoRoot: repoRoot)
    }
}

/// Process-environment backstop behind ``RunEnvironment/validateWrite(to:)``
/// for writers below the CLI (artifact emitters, the result cache).
///
/// The CLI exports ``environmentVariable`` when a run is foreign — the same
/// pattern `QG_NO_INDEX_BUILD` uses to reach `StoreLocator` — and every deep
/// writer calls ``validate(path:environment:)`` before touching disk. When
/// the variable is unset (every resident run), validation is a no-op.
public enum WriteGuard {
    /// Set by the CLI to the analyzed repo's root in foreign mode.
    public static let environmentVariable = "QG_FOREIGN_REPO_ROOT"

    /// Confirms a write destination is legal under the active environment.
    ///
    /// - Parameters:
    ///   - path: The write destination a caller is about to use.
    ///   - environment: Process environment (injectable for tests).
    /// - Throws: ``QualityGateError/writeGuardViolation(path:)`` when a
    ///   foreign run attempts a write inside the analyzed repo.
    public static func validate(
        path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard let root = environment[environmentVariable], !root.isEmpty else { return }
        let target = URL(fileURLWithPath: path)
        if RunEnvironment.path(target, isInside: URL(fileURLWithPath: root, isDirectory: true)) {
            throw QualityGateError.writeGuardViolation(path: target.standardizedFileURL.path)
        }
    }
}
