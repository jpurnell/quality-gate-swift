import Foundation

/// A named individual assigned to a specific decision role in a design proposal.
public struct RoleAssignment: Sendable, Codable, Equatable {
    /// The individual's name.
    public let name: String
    /// The individual's organizational role.
    public let role: String
    /// The specific action this role must perform (e.g., "Approve Step 0 Proposal").
    public let requiredAction: String

    /// Creates a new role assignment.
    /// - Parameters:
    ///   - name: The individual's name.
    ///   - role: The individual's organizational role.
    ///   - requiredAction: The specific action this role must perform.
    public init(name: String, role: String, requiredAction: String) {
        self.name = name
        self.role = role
        self.requiredAction = requiredAction
    }
}

/// Assigns authority for key decision points in a design proposal.
///
/// Prevents "decision compression" — the failure mode where whoever moves fastest
/// becomes the default decision-maker. Integrated into `05_DESIGN_PROPOSAL.md`.
public struct DecisionResponsibilityMatrix: Sendable, Codable, Equatable {
    /// Who approves the Step 0 architectural proposal.
    public let architecturalSignoff: RoleAssignment
    /// Who approves Tier 2+ quality gate bypasses.
    public let overrideAuthority: RoleAssignment
    /// Who provides formal dissent/review (the "immune system").
    public let redTeamChallenge: RoleAssignment
    /// Who decides to move from prototype to product.
    public let finalShippingRights: RoleAssignment
    /// The risk classification for this feature.
    public let assignedRiskTier: RiskTier
    /// Regulatory, brand, or operational requirements that apply.
    public let contextualConstraints: [String]

    /// Creates a new decision responsibility matrix.
    /// - Parameters:
    ///   - architecturalSignoff: Who approves the architectural proposal.
    ///   - overrideAuthority: Who approves quality gate bypasses.
    ///   - redTeamChallenge: Who provides formal dissent.
    ///   - finalShippingRights: Who decides prototype-to-product.
    ///   - assignedRiskTier: Risk classification for this feature.
    ///   - contextualConstraints: Applicable regulatory or brand requirements.
    public init(
        architecturalSignoff: RoleAssignment,
        overrideAuthority: RoleAssignment,
        redTeamChallenge: RoleAssignment,
        finalShippingRights: RoleAssignment,
        assignedRiskTier: RiskTier,
        contextualConstraints: [String]
    ) {
        self.architecturalSignoff = architecturalSignoff
        self.overrideAuthority = overrideAuthority
        self.redTeamChallenge = redTeamChallenge
        self.finalShippingRights = finalShippingRights
        self.assignedRiskTier = assignedRiskTier
        self.contextualConstraints = contextualConstraints
    }
}
