import Foundation

/// Classifies a project's engagement level based on run frequency and recency.
///
/// Used by Pulse Statistical Maturity to determine whether a project has
/// sufficient recent activity to produce meaningful trend analysis.
public enum ProjectTier: String, Sendable, Codable, Comparable {
    case dormant
    case atRisk
    case firstContact
    case baseline
    case active

    /// Compares tiers by engagement level (dormant < active).
    public static func < (lhs: ProjectTier, rhs: ProjectTier) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    /// Classifies a project based on recency and volume of quality-gate runs.
    /// - Parameters:
    ///   - runCountInWindow: Total runs within the analysis window.
    ///   - daysSinceLastRun: Calendar days since the most recent run.
    public static func classify(
        runCountInWindow: Int,
        daysSinceLastRun: Int
    ) -> ProjectTier {
        if daysSinceLastRun >= 30 { return .dormant }
        if daysSinceLastRun >= 21 { return .atRisk }
        if runCountInWindow < 3 { return .firstContact }
        return .active
    }

    private var sortOrder: Int {
        switch self {
        case .dormant: 0
        case .atRisk: 1
        case .firstContact: 2
        case .baseline: 3
        case .active: 4
        }
    }
}
