import Foundation
import IJSSensor

/// Computes institutional consistency scores from ConsistencyReport findings.
///
/// Scoring algorithm:
/// 1. Start at 1.0 (fully consistent)
/// 2. For each finding, deduct based on type and recurrence
/// 3. Optionally discount by baseline validity
/// 4. Clamp to [0.0, 1.0]
public struct ConsistencyScorer: Sendable {

    /// The weights used for scoring deductions.
    public let weights: ScorerWeights

    /// Creates a scorer with default weights.
    public init() {
        self.weights = .defaults
    }

    /// Creates a scorer with custom weights.
    /// - Parameter weights: The deduction weights to use.
    public init(weights: ScorerWeights) {
        self.weights = weights
    }

    /// Computes a consistency score from findings with full-weight deductions.
    public func score(findings: [ConsistencyFinding]) -> Double {
        let totalDeduction = findings.reduce(0.0) { total, finding in
            total + deduction(for: finding)
        }
        return max(0.0, min(1.0, 1.0 - totalDeduction))
    }

    /// Computes a consistency score, discounting by baseline validity.
    public func score(
        findings: [ConsistencyFinding],
        baselineValidity: StatisticalValidity
    ) -> Double {
        let totalDeduction = findings.reduce(0.0) { total, finding in
            total + deduction(for: finding)
        }
        let discounted = totalDeduction * validityMultiplier(for: baselineValidity)
        return max(0.0, min(1.0, 1.0 - discounted))
    }

    private func deduction(for finding: ConsistencyFinding) -> Double {
        let base: Double
        switch finding.matchType {
        case .clusterMatch:
            base = weights.clusterMatch
        case .anomalyPattern:
            base = weights.anomalyPattern
        case .unaddressedPolicy:
            base = weights.unaddressedPolicy
        }
        return finding.isRecurringInPulse ? base + weights.recurrenceBonus : base
    }

    private func validityMultiplier(for validity: StatisticalValidity) -> Double {
        switch validity {
        case .valid:
            return 1.0
        case .preliminary:
            return 0.5
        case .insufficient:
            return 0.25
        }
    }
}
