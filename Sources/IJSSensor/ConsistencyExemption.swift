import Foundation

/// A documented exemption from consistency finding matching.
///
/// When a ruleId keeps triggering consistency findings but the occurrences
/// are contextually different from the original pattern, the team can exempt
/// specific ruleId + matchType combinations. Every exemption requires a
/// justification — silent suppression is not allowed.
public struct ConsistencyExemption: Sendable, Codable, Equatable {
    /// The rule ID to exempt from consistency matching.
    public let ruleId: String
    /// Which match type to exempt. Nil means exempt from all match types.
    public let matchType: ConsistencyMatchType?
    /// Why this exemption exists. Mandatory — no silent suppression.
    public let justification: String
    /// When this exemption was added (for staleness tracking).
    public let addedDate: Date
    /// Who approved this exemption.
    public let approvedBy: String

    /// Creates a new consistency exemption.
    /// - Parameters:
    ///   - ruleId: The rule ID to exempt.
    ///   - matchType: Which match type to exempt; nil exempts all.
    ///   - justification: Why this exemption exists.
    ///   - addedDate: When the exemption was added.
    ///   - approvedBy: Who approved the exemption.
    public init(
        ruleId: String,
        matchType: ConsistencyMatchType?,
        justification: String,
        addedDate: Date,
        approvedBy: String
    ) {
        self.ruleId = ruleId
        self.matchType = matchType
        self.justification = justification
        self.addedDate = addedDate
        self.approvedBy = approvedBy
    }
}
