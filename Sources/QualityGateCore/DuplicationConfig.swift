import Foundation

/// Configuration for ``DuplicationAuditor``: window size, diversity floor,
/// severity posture, and test-tree inclusion.
///
/// Decoding tolerates absent keys — every field falls back to its default —
/// so a partial `duplication:` block in `.quality-gate.yml` is valid.
public struct DuplicationConfig: Sendable, Codable, Equatable {

    /// Sliding-window size in normalized tokens. A clone must span at least
    /// this many consecutive normalized tokens to be reported. Default 175 —
    /// substantial enough that only duplication worth acting on surfaces; the
    /// old default of 80 (~10 lines) drowned the inbox in narrow matches.
    public var minTokens: Int

    /// Minimum count of *distinct* normalized token texts a clone class's
    /// representative block must contain. Classes below this floor are dropped
    /// as low-variety boilerplate (e.g. long runs of `case .x: return …`).
    /// Default 12.
    public var minDistinctTokens: Int

    /// Escalates findings from `.note` to `.warning` (and the check status
    /// from `.passed` to `.warning` when clones are found). Default `false` —
    /// duplication findings are advisory.
    public var warnOnClones: Bool

    /// Skips the `Tests/` tree entirely when `true`. Default `true`: parallel
    /// test structure is desirable design, not duplication worth flagging.
    public var excludeTests: Bool

    /// Creates a duplication configuration.
    ///
    /// - Parameters:
    ///   - minTokens: Sliding-window size in normalized tokens (default 175).
    ///   - minDistinctTokens: Distinct-token floor per clone class (default 12).
    ///   - warnOnClones: Escalate findings to `.warning` (default `false`).
    ///   - excludeTests: Skip the `Tests/` tree (default `true`).
    public init(
        minTokens: Int = 175,
        minDistinctTokens: Int = 12,
        warnOnClones: Bool = false,
        excludeTests: Bool = true
    ) {
        self.minTokens = minTokens
        self.minDistinctTokens = minDistinctTokens
        self.warnOnClones = warnOnClones
        self.excludeTests = excludeTests
    }

    private enum CodingKeys: String, CodingKey {
        case minTokens, minDistinctTokens, warnOnClones, excludeTests
    }

    /// Decodes with defaults for absent optional keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minTokens = try container.decodeIfPresent(Int.self, forKey: .minTokens) ?? 175
        minDistinctTokens = try container.decodeIfPresent(Int.self, forKey: .minDistinctTokens) ?? 12
        warnOnClones = try container.decodeIfPresent(Bool.self, forKey: .warnOnClones) ?? false
        excludeTests = try container.decodeIfPresent(Bool.self, forKey: .excludeTests) ?? true
    }
}
