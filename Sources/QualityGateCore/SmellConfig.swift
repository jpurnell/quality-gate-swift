import Foundation

/// Thresholds for the advisory smell-metric suite (Phase 4c §4).
///
/// Every metric flags strictly *over* its threshold; a measurement exactly at
/// the threshold is quiet. All knobs are config-tunable; the defaults follow
/// common industry practice for the corresponding SwiftLint/Sonar metrics.
public struct SmellConfig: Sendable, Codable, Equatable {
    /// Maximum parameters a function or initializer may declare. Default 5.
    public var maxParameterCount: Int
    /// Maximum statement nesting depth inside one function body. Default 4.
    public var maxNestingDepth: Int
    /// Maximum members a type may have, counting same-file extensions. Default 30.
    public var maxTypeMemberCount: Int
    /// Maximum lines a type body may span, braces inclusive. Default 500.
    public var maxTypeBodyLength: Int
    /// Maximum lines a closure body may span, braces inclusive. Default 50.
    public var maxClosureLength: Int

    /// Creates a threshold set; every knob defaults to the documented value.
    public init(
        maxParameterCount: Int = 5,
        maxNestingDepth: Int = 4,
        maxTypeMemberCount: Int = 30,
        maxTypeBodyLength: Int = 500,
        maxClosureLength: Int = 50
    ) {
        self.maxParameterCount = maxParameterCount
        self.maxNestingDepth = maxNestingDepth
        self.maxTypeMemberCount = maxTypeMemberCount
        self.maxTypeBodyLength = maxTypeBodyLength
        self.maxClosureLength = maxClosureLength
    }

    private enum CodingKeys: String, CodingKey {
        case maxParameterCount, maxNestingDepth, maxTypeMemberCount
        case maxTypeBodyLength, maxClosureLength
    }

    /// Decodes with defaults for absent keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxParameterCount = try container.decodeIfPresent(Int.self, forKey: .maxParameterCount) ?? 5
        maxNestingDepth = try container.decodeIfPresent(Int.self, forKey: .maxNestingDepth) ?? 4
        maxTypeMemberCount = try container.decodeIfPresent(Int.self, forKey: .maxTypeMemberCount) ?? 30
        maxTypeBodyLength = try container.decodeIfPresent(Int.self, forKey: .maxTypeBodyLength) ?? 500
        maxClosureLength = try container.decodeIfPresent(Int.self, forKey: .maxClosureLength) ?? 50
    }
}
