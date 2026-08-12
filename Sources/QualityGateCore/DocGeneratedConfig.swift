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

    /// Prepended to a version to form the git ref a changelog link points at, e.g. `"v"` for
    /// tags spelled `v2.0.2`.
    ///
    /// Configured for the same reason as ``repositoryURL`` and one more. A tag name is not in
    /// the working tree at all, so nothing can derive it; and unlike every other comparison
    /// this checker makes, the two sides cannot be normalised into agreement. `release-readiness`
    /// reduces `v2.0.2`, `2.0.2` and `Project@v2.0.2` to one bare semver before comparing, which
    /// is right when the question is *are these the same version*. A URL has to name the ref
    /// exactly, so the variance it absorbs has to be settled here instead.
    ///
    /// Defaults to the empty string: the heading as written. A repository whose tags do not all
    /// follow one convention cannot be served by any value, which is a defect in its tags rather
    /// than a case for this knob to handle — and one this checker cannot see, since refs are not
    /// files (§7, *anything outside the working tree*).
    public var tagPrefix: String

    /// Creates a configuration; every knob defaults to the documented value.
    public init(
        additionalFiles: [String] = [],
        repositoryURL: String? = nil,
        tagPrefix: String = ""
    ) {
        self.additionalFiles = additionalFiles
        self.repositoryURL = repositoryURL
        self.tagPrefix = tagPrefix
    }

    private enum CodingKeys: String, CodingKey {
        case additionalFiles, repositoryURL, tagPrefix
    }

    /// Decodes with defaults for absent keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        additionalFiles = try container.decodeIfPresent([String].self, forKey: .additionalFiles) ?? []
        repositoryURL = try container.decodeIfPresent(String.self, forKey: .repositoryURL)
        tagPrefix = try container.decodeIfPresent(String.self, forKey: .tagPrefix) ?? ""
    }
}
