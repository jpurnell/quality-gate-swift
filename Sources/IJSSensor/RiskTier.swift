import Foundation

/// The level of authority required to approve an override at a given risk tier.
public enum AuthorityLevel: String, Sendable, Codable {
    /// The practitioner who authored the code may self-approve.
    case practitioner
    /// A peer or red-team reviewer must co-sign.
    case peer
    /// The designated decision owner from the DRM must approve.
    case decisionOwner
    /// Executive or legal sign-off is required.
    case executive
}

/// Categorizes quality gate events by their potential for systemic impact.
///
/// Each tier prescribes escalating friction and authority requirements,
/// ensuring that higher-risk overrides receive proportionally more scrutiny.
///
/// - ``informational``: Style, documentation, formatting.
/// - ``operational``: Stability, performance, operational concerns.
/// - ``safety``: Safety-critical or security-sensitive patterns.
/// - ``critical``: Ethical, strategic, or regulatory impact.
public enum RiskTier: Int, Sendable, Codable, Comparable {
    /// Style, documentation, formatting. Practitioner sign-off.
    case informational = 1
    /// Stability, performance, operational. Peer/Red-Team sign-off.
    case operational = 2
    /// Safety-critical, security-sensitive. Decision Owner + Pre-Mortem.
    case safety = 3
    /// Ethical, strategic, regulatory. Executive/Legal sign-off.
    case critical = 4

    /// The minimum authority level required to approve an override at this tier.
    public var requiredAuthority: AuthorityLevel {
        switch self {
        case .informational: .practitioner
        case .operational: .peer
        case .safety: .decisionOwner
        case .critical: .executive
        }
    }

    /// Compares risk tiers by severity (lower raw value = lower risk).
    public static func < (lhs: RiskTier, rhs: RiskTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
