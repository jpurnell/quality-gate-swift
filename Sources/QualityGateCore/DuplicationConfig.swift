import Foundation

/// Configuration for ``DuplicationAuditor``: window size, severity posture,
/// and test-tree inclusion.
///
/// Decoding tolerates absent keys — every field falls back to its default —
/// so a partial `duplication:` block in `.quality-gate.yml` is valid.
public struct DuplicationConfig: Sendable, Codable, Equatable {

    /// Sliding-window size in normalized tokens. A clone must span at least
    /// this many consecutive normalized tokens to be reported. Default 80.
    public var minTokens: Int

    /// Escalates findings from `.note` to `.warning` (and the check status
    /// from `.passed` to `.warning` when clones are found). Default `false` —
    /// duplication findings are advisory.
    public var warnOnClones: Bool

    /// Skips the `Tests/` tree entirely when `true`. Default `false`.
    public var excludeTests: Bool

    /// Creates a duplication configuration.
    ///
    /// - Parameters:
    ///   - minTokens: Sliding-window size in normalized tokens (default 80).
    ///   - warnOnClones: Escalate findings to `.warning` (default `false`).
    ///   - excludeTests: Skip the `Tests/` tree (default `false`).
    public init(
        minTokens: Int = 80,
        warnOnClones: Bool = false,
        excludeTests: Bool = false
    ) {
        self.minTokens = minTokens
        self.warnOnClones = warnOnClones
        self.excludeTests = excludeTests
    }

    private enum CodingKeys: String, CodingKey {
        case minTokens, warnOnClones, excludeTests
    }

    /// Decodes with defaults for absent optional keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minTokens = try container.decodeIfPresent(Int.self, forKey: .minTokens) ?? 80
        warnOnClones = try container.decodeIfPresent(Bool.self, forKey: .warnOnClones) ?? false
        excludeTests = try container.decodeIfPresent(Bool.self, forKey: .excludeTests) ?? false
    }
}
