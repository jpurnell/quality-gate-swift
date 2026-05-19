import Foundation
import Yams

/// The lifecycle state of a project within the corpus.
///
/// Projects start as ``active`` and may be moved to ``sunset``
/// when they are no longer under active development. The lifecycle
/// state is stored in the corpus manifest (`manifest.yml`).
public enum ProjectLifecycle: String, Sendable, Codable, Equatable, CaseIterable {
    /// The project is actively maintained and included in portfolio metrics.
    case active
    /// The project has been retired and excluded from active portfolio counts.
    case sunset
}

/// A single entry in the corpus manifest describing a project's lifecycle state.
///
/// This is a read-only model. Full mutation of the manifest is handled
/// by the org-judgement-system CLI.
public struct CorpusManifestEntry: Sendable, Codable, Equatable {
    /// The lifecycle state of the project.
    public let lifecycle: ProjectLifecycle
    /// Optional reason for the lifecycle state (e.g., why a project was sunset).
    public let reason: String?
    /// When the lifecycle state was last changed.
    public let changedAt: Date

    /// Creates a new manifest entry.
    /// - Parameters:
    ///   - lifecycle: The lifecycle state of the project.
    ///   - reason: Optional reason for the lifecycle state.
    ///   - changedAt: When the lifecycle state was last changed.
    public init(lifecycle: ProjectLifecycle, reason: String? = nil, changedAt: Date) {
        self.lifecycle = lifecycle
        self.reason = reason
        self.changedAt = changedAt
    }
}

/// A corpus manifest mapping project IDs to their lifecycle metadata.
///
/// Stored as `manifest.yml` in the corpus root. Projects not present
/// in the manifest are assumed to be ``ProjectLifecycle/active``.
public struct CorpusManifest: Sendable, Codable, Equatable {
    /// Per-project lifecycle entries keyed by project ID.
    public var projects: [String: CorpusManifestEntry]

    /// Creates a new manifest.
    /// - Parameter projects: Per-project lifecycle entries keyed by project ID.
    public init(projects: [String: CorpusManifestEntry] = [:]) {
        self.projects = projects
    }

    /// Returns the lifecycle state for a project, defaulting to ``ProjectLifecycle/active``.
    /// - Parameter projectID: The project identifier to look up.
    /// - Returns: The project's lifecycle state, or `.active` if not in the manifest.
    public func lifecycle(for projectID: String) -> ProjectLifecycle {
        projects[projectID]?.lifecycle ?? .active
    }

    /// Loads a manifest from a YAML file at the given URL.
    ///
    /// Returns an empty manifest (all projects treated as active) if the
    /// file does not exist.
    ///
    /// - Parameter url: The file URL of the `manifest.yml` file.
    /// - Returns: The decoded manifest.
    /// - Throws: ``IJSError/configurationError(reason:)`` if the file exists but cannot be parsed.
    public static func load(from url: URL) throws -> CorpusManifest {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { // SAFETY: read-only check on configured path
            return CorpusManifest()
        }

        let yamlString: String
        do {
            yamlString = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw IJSError.configurationError(reason: "Cannot read manifest: \(error.localizedDescription)")
        }

        guard let root = try? Yams.load(yaml: yamlString) as? [String: Any] else { // silent: guard-else provides descriptive error
            throw IJSError.configurationError(reason: "Invalid YAML structure in manifest")
        }

        guard let projectsSection = root["projects"] as? [String: Any] else {
            // Empty or missing projects section is valid — all projects are active
            return CorpusManifest()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var entries: [String: CorpusManifestEntry] = [:]
        for (projectID, value) in projectsSection {
            guard let entryDict = value as? [String: Any] else { continue }
            guard let lifecycleRaw = entryDict["lifecycle"] as? String,
                  let lifecycle = ProjectLifecycle(rawValue: lifecycleRaw) else { continue }
            guard let changedAtString = entryDict["changedAt"] as? String else { continue }

            let changedAt: Date
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = iso8601Formatter.date(from: changedAtString) {
                changedAt = parsed
            } else {
                let fallbackFormatter = ISO8601DateFormatter()
                fallbackFormatter.formatOptions = [.withInternetDateTime]
                guard let fallbackParsed = fallbackFormatter.date(from: changedAtString) else {
                    continue
                }
                changedAt = fallbackParsed
            }

            let reason = entryDict["reason"] as? String
            entries[projectID] = CorpusManifestEntry(
                lifecycle: lifecycle,
                reason: reason,
                changedAt: changedAt
            )
        }

        return CorpusManifest(projects: entries)
    }
}
