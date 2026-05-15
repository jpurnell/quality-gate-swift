import Foundation

/// Separates proximate causes (actions) from root causes (adjectives describing the decision process).
///
/// Follows Dalio's diagnostic methodology with one deliberate departure:
/// the ``rootCause`` adjective describes the *decision process*, not the *person*
/// (ADR-001). For example, "expedient" rather than "impatient."
public struct RootCauseAnalysis: Sendable, Codable, Equatable {
    /// The specific action or inaction that led to the problem.
    public let proximateCause: String

    /// Chain of "Why?" questions drilling from symptom to organizational flaw.
    public let chainOfInquiry: [String]

    /// Adjective describing the decision process (not the person).
    public let rootCause: String

    /// Which stage of the 5-Step Process failed.
    public let failedStep: FiveStepStage

    /// Whether this failure is part of a recurring pattern across projects.
    public let isRecurringPattern: Bool

    /// Creates a new root cause analysis.
    /// - Parameters:
    ///   - proximateCause: The specific action that led to the problem.
    ///   - chainOfInquiry: Chain of "Why?" questions from symptom to root.
    ///   - rootCause: Adjective describing the decision process.
    ///   - failedStep: Which 5-Step stage failed.
    ///   - isRecurringPattern: Whether this is a recurring pattern.
    public init(
        proximateCause: String,
        chainOfInquiry: [String],
        rootCause: String,
        failedStep: FiveStepStage,
        isRecurringPattern: Bool
    ) {
        self.proximateCause = proximateCause
        self.chainOfInquiry = chainOfInquiry
        self.rootCause = rootCause
        self.failedStep = failedStep
        self.isRecurringPattern = isRecurringPattern
    }
}
