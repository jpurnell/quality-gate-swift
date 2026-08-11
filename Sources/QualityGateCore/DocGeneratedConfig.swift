import Foundation

/// Configuration for the `doc-generated` checker.
///
/// Everything here widens *what* is scanned or supplies a fact a generator cannot derive
/// from the tree. Nothing here weakens a verdict: per `DocCodeConfig`'s rule, a knob that
/// turns a red gate green is a suppression by another name, so there is deliberately no way
/// to downgrade a stale region to a warning. Debt is carried by `quality-gate adopt`, which
/// carries it visibly and with an expiry date.
public struct DocGeneratedConfig: Sendable, Codable, Equatable {

    /// Extra markdown files to scan for regions, as paths relative to the project root.
    ///
    /// Additive to the governed set (`README.md`, `CHANGELOG.md`, and the master plan named
    /// by the `status` section) — never a replacement, so a configured path cannot narrow
    /// coverage by accident.
    public var additionalFiles: [String]

    /// The repository's web URL, used to build `CHANGELOG.md`'s link-reference definitions.
    ///
    /// Deliberately configured rather than read from `git remote`. A ref is not the working
    /// tree: a shallow clone, a mirror, or a fresh CI checkout would change the generated
    /// text without changing a byte of source, and a verdict that moves for reasons outside
    /// the tree cannot claim to be hermetic. When it is absent the region reports as
    /// ungeneratable rather than guessing.
    public var repositoryURL: String?

    /// Creates a configuration; every knob defaults to the documented value.
    public init(
        additionalFiles: [String] = [],
        repositoryURL: String? = nil
    ) {
        self.additionalFiles = additionalFiles
        self.repositoryURL = repositoryURL
    }

    private enum CodingKeys: String, CodingKey {
        case additionalFiles, repositoryURL
    }

    /// Decodes with defaults for absent keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        additionalFiles = try container.decodeIfPresent([String].self, forKey: .additionalFiles) ?? []
        repositoryURL = try container.decodeIfPresent(String.self, forKey: .repositoryURL)
    }
}
