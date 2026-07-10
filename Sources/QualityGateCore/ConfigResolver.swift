import Foundation
import Yams

/// Where a resolved configuration section came from.
///
/// One origin per top-level YAML key: the first layer (repo → overlay →
/// user-global) that declares a section owns it wholly; sections declared
/// nowhere fall through to `.builtin` defaults.
public enum ConfigOrigin: Sendable, Equatable {
    /// The repository's own `.quality-gate.yml` — the project's declared policy.
    case repo
    /// The per-project overlay `config.yml` under `~/.quality-gate/overlays/`.
    case overlay
    /// The user-global `~/.quality-gate/config.yml`.
    case userGlobal
    /// No file declared the section; built-in defaults apply.
    case builtin

    /// Human-readable label used by `renderTable()` and `config --explain`.
    public var label: String {
        switch self {
        case .repo: return "repo"
        case .overlay: return "overlay"
        case .userGlobal: return "user-global"
        case .builtin: return "built-in"
        }
    }
}

/// A per-section record of where the effective configuration came from.
///
/// Surfaced by `quality-gate config --explain` so "which config am I
/// running?" has a one-command answer.
public struct ConfigProvenance: Sendable, Equatable {
    /// Origin of every section that was declared in *some* file.
    /// Sections resolved from built-in defaults are absent by design —
    /// query them via ``origin(of:)``.
    public var sections: [String: ConfigOrigin]

    /// Path of the repo `.quality-gate.yml`, if one existed.
    public var repoConfigPath: String?

    /// Path of the overlay `config.yml`, if one existed.
    public var overlayConfigPath: String?

    /// Path of the user-global `config.yml`, if one existed.
    public var userGlobalConfigPath: String?

    /// Creates a provenance record.
    ///
    /// - Parameters:
    ///   - sections: Origin per file-declared top-level section.
    ///   - repoConfigPath: Consulted repo config path, if present on disk.
    ///   - overlayConfigPath: Consulted overlay config path, if present on disk.
    ///   - userGlobalConfigPath: Consulted user-global config path, if present on disk.
    public init(
        sections: [String: ConfigOrigin] = [:],
        repoConfigPath: String? = nil,
        overlayConfigPath: String? = nil,
        userGlobalConfigPath: String? = nil
    ) {
        self.sections = sections
        self.repoConfigPath = repoConfigPath
        self.overlayConfigPath = overlayConfigPath
        self.userGlobalConfigPath = userGlobalConfigPath
    }

    /// The origin of a section, `.builtin` when no file declared it.
    ///
    /// - Parameter section: A top-level configuration key, e.g. `"complexity"`.
    /// - Returns: The layer that owns the section.
    public func origin(of section: String) -> ConfigOrigin {
        sections[section] ?? .builtin
    }

    /// Renders the provenance as an aligned text table for `config --explain`.
    ///
    /// - Returns: Section/origin rows (alphabetical) followed by the list of
    ///   consulted files, `(none)` marking layers with no file on disk.
    public func renderTable() -> String {
        var lines: [String] = []
        let width = max(sections.keys.map(\.count).max() ?? 0, "Section".count) + 2
        lines.append("Section".padding(toLength: width, withPad: " ", startingAt: 0) + "Origin")
        for key in sections.keys.sorted() {
            let origin = origin(of: key)
            lines.append(key.padding(toLength: width, withPad: " ", startingAt: 0) + origin.label)
        }
        if sections.isEmpty {
            lines.append("(all sections at built-in defaults)")
        }
        lines.append("")
        lines.append("Consulted files:")
        lines.append("  repo:        \(repoConfigPath ?? "(none)")")
        lines.append("  overlay:     \(overlayConfigPath ?? "(none)")")
        lines.append("  user-global: \(userGlobalConfigPath ?? "(none)")")
        return lines.joined(separator: "\n")
    }
}

/// Resolves the effective ``Configuration`` from layered sources.
///
/// Resolution order, **first hit per top-level section**:
/// 1. repo `.quality-gate.yml` (the project's own contract — always wins)
/// 2. overlay `config.yml` (contributor state for repos that aren't theirs)
/// 3. user-global `config.yml` (personal defaults)
/// 4. built-in defaults
///
/// Sections are atomic: a layer that declares a section owns every key in it;
/// lower layers never deep-merge into it. Merging happens on raw YAML nodes,
/// so configuration fields added later inherit overlay support automatically.
public struct ConfigResolver: Sendable {
    /// File name of a repository's own configuration.
    public static let repoConfigFileName = ".quality-gate.yml"

    /// Location of the repo-layer config file.
    public let repoConfigURL: URL

    /// Location of the per-project overlay config, if the caller has one.
    public let overlayConfigURL: URL?

    /// Location of the user-global config, if the caller has one.
    public let userGlobalConfigURL: URL?

    /// Creates a resolver over explicit source locations.
    ///
    /// Paths that don't exist on disk are skipped silently — absence is the
    /// normal state for overlay and global layers.
    ///
    /// - Parameters:
    ///   - repoConfigURL: The repo-layer config file (the CLI's `--config`
    ///     value; conventionally `<repoRoot>/.quality-gate.yml`).
    ///   - overlayConfigURL: Overlay `config.yml` location, or nil for none.
    ///   - userGlobalConfigURL: User-global `config.yml` location, or nil for none.
    public init(repoConfigURL: URL, overlayConfigURL: URL? = nil, userGlobalConfigURL: URL? = nil) {
        self.repoConfigURL = repoConfigURL
        self.overlayConfigURL = overlayConfigURL
        self.userGlobalConfigURL = userGlobalConfigURL
    }

    /// Creates a resolver whose repo layer is `<repoRoot>/.quality-gate.yml`.
    ///
    /// - Parameters:
    ///   - repoRoot: Repository root directory.
    ///   - overlayConfigURL: Overlay `config.yml` location, or nil for none.
    ///   - userGlobalConfigURL: User-global `config.yml` location, or nil for none.
    public init(repoRoot: URL, overlayConfigURL: URL? = nil, userGlobalConfigURL: URL? = nil) {
        self.init(
            repoConfigURL: repoRoot.appendingPathComponent(Self.repoConfigFileName),
            overlayConfigURL: overlayConfigURL,
            userGlobalConfigURL: userGlobalConfigURL)
    }

    /// Resolves the effective configuration and its provenance.
    ///
    /// - Returns: The merged configuration plus a per-section origin record.
    /// - Throws: ``QualityGateError/configurationError(_:)`` when any present
    ///   layer is unreadable, not valid YAML, or not a mapping — a broken
    ///   config is an error to fix, never a silent fallback.
    public func resolve() throws -> (configuration: Configuration, provenance: ConfigProvenance) {
        let layers: [(url: URL?, origin: ConfigOrigin)] = [
            (repoConfigURL, .repo),
            (overlayConfigURL, .overlay),
            (userGlobalConfigURL, .userGlobal),
        ]

        var mergedPairs: [(Node, Node)] = []
        var claimed: Set<String> = []
        var provenance = ConfigProvenance()

        for layer in layers {
            guard let url = layer.url,
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            switch layer.origin {
            case .repo: provenance.repoConfigPath = url.path
            case .overlay: provenance.overlayConfigPath = url.path
            case .userGlobal: provenance.userGlobalConfigPath = url.path
            case .builtin: break
            }
            for (key, value) in try topLevelEntries(of: url) where !claimed.contains(key.0) {
                claimed.insert(key.0)
                provenance.sections[key.0] = layer.origin
                mergedPairs.append((key.1, value))
            }
        }

        guard !mergedPairs.isEmpty else {
            return (Configuration(), provenance)
        }

        let mergedYAML: String
        do {
            mergedYAML = try Yams.serialize(node: Node.mapping(.init(mergedPairs)))
        } catch {
            throw QualityGateError.configurationError(
                "Failed to merge configuration layers: \(error.localizedDescription)")
        }
        return (try Configuration.from(yaml: mergedYAML), provenance)
    }

    /// Reads one layer and returns its top-level entries in document order.
    ///
    /// - Parameter url: A config file known to exist.
    /// - Returns: Pairs of (string key + original key node, value node).
    ///   An empty document yields no entries.
    /// - Throws: ``QualityGateError/configurationError(_:)`` for unreadable
    ///   files, YAML syntax errors, non-mapping documents, or non-string keys.
    private func topLevelEntries(of url: URL) throws -> [((String, Node), Node)] {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw QualityGateError.configurationError(
                "Failed to read \(url.path): \(error.localizedDescription)")
        }

        let document: Node?
        do {
            document = try Yams.compose(yaml: contents)
        } catch {
            throw QualityGateError.configurationError(
                "Invalid YAML in \(url.path): \(error.localizedDescription)")
        }

        guard let document else { return [] }
        guard case .mapping(let mapping) = document else {
            throw QualityGateError.configurationError(
                "Configuration at \(url.path) must be a YAML mapping of sections")
        }

        var entries: [((String, Node), Node)] = []
        for (key, value) in mapping {
            guard let name = key.string else {
                throw QualityGateError.configurationError(
                    "Configuration at \(url.path) has a non-string top-level key")
            }
            entries.append(((name, key), value))
        }
        return entries
    }
}
