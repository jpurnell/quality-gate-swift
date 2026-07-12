import CorpusService
import Foundation

/// The governed-acknowledge decision (Phase 3b §3): what happens when a
/// human acknowledges a finding whose rule the review policy governs.
///
/// Pure over its inputs so the whole state machine is table-testable. A
/// review "matches" on (ruleId, justification) — a different reason is a
/// different judgment and starts its own review.
public enum GovernedAcknowledge {

    /// The decided action for one acknowledge attempt.
    public enum Action: Sendable, Equatable {
        /// Ungoverned (or approved) — write the marker now.
        case writeMarker
        /// Governed with no matching review — submit and hold.
        case submitForReview
        /// A matching review exists and is still pending.
        case awaitingSecondIdentity
        /// A matching review was rejected — the acknowledge does not happen.
        case rejected(by: String, reason: String)
    }

    /// Decides the action for an acknowledge attempt.
    ///
    /// - Parameters:
    ///   - policy: The org review policy; nil means solo mode (no governance).
    ///   - reviews: Every review on record, any state.
    ///   - ruleId: The rule being acknowledged.
    ///   - reason: The human's justification.
    public static func decide(
        policy: ReviewPolicy?,
        reviews: [PendingReview],
        ruleId: String,
        reason: String
    ) -> Action {
        guard let policy, policy.requiresSecondReviewer(for: ruleId) else {
            return .writeMarker
        }
        let matches = reviews.filter { $0.ruleId == ruleId && $0.justification == reason }
        // The newest matching review speaks for the judgment's current state.
        guard let latest = matches.max(by: { $0.submittedAt < $1.submittedAt }) else {
            return .submitForReview
        }
        switch latest.state {
        case .pending:
            return .awaitingSecondIdentity
        case .approved:
            return .writeMarker
        case .rejected(let by, _, let reason):
            return .rejected(by: by, reason: reason)
        }
    }
}
