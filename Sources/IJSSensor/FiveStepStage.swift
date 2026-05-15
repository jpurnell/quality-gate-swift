import Foundation

/// Identifies which stage of Dalio's 5-Step Process failed in a root cause analysis.
///
/// Each stage requires a different type of thinking. Chronic failure at one stage
/// indicates a gap in the specific capability that stage demands.
public enum FiveStepStage: String, Sendable, Codable {
    /// Failure of higher-level thinking — wrong goals or misplaced priorities.
    case goals // LIVE: five-step methodology stage enum
    /// Failure of perception — problems tolerated or overlooked.
    case problems // LIVE: five-step methodology stage enum
    /// Failure of logic — root causes not found, hard conversations avoided.
    case diagnosis // LIVE: five-step methodology stage enum
    /// Failure of visualization — flawed plan for how components interact.
    case design // LIVE: five-step methodology stage enum
    /// Failure of discipline — poor execution or weak follow-through.
    case doing // LIVE: five-step methodology stage enum
}
