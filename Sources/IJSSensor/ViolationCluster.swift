import Foundation

/// A recurring pattern of violations detected across telemetry within a time window.
///
/// Clusters are identified by matching `ruleId` values across multiple gate runs.
/// A cluster signals an institutional gap — the same mistake keeps happening,
/// suggesting missing guidance rather than individual error.
public struct ViolationCluster: Sendable, Codable, Equatable {
    /// The rule ID that recurs (e.g., "concurrency.unchecked-sendable").
    public let ruleId: String
    /// How many times this rule was violated in the time window.
    public let occurrenceCount: Int
    /// How many distinct projects triggered this rule.
    public let affectedProjectCount: Int
    /// The most common root cause adjective from calibrations referencing this rule.
    public let dominantRootCause: String?
    /// The most common failed 5-Step stage from calibrations referencing this rule.
    public let dominantFailedStep: FiveStepStage?
    /// Whether this cluster appeared in the previous Pulse (recurring vs. new).
    /// Requires at least 3 consecutive pulse appearances to become true.
    public let isRecurring: Bool
    /// How many consecutive pulses this cluster has appeared in.
    public let consecutiveAppearances: Int?
    /// Occurrence count from the prior pulse.
    public let priorOccurrenceCount: Int?
    /// Affected project count from the prior pulse.
    public let priorProjectCount: Int?
    /// Occurrence count from the absolute latest run per project (live state).
    public let currentOccurrenceCount: Int?
    /// Affected project count from the absolute latest run per project (live state).
    public let currentProjectCount: Int?
    /// Project names with violations in the window.
    public let affectedProjects: [String]?
    /// Project names with violations in live state.
    public let currentAffectedProjects: [String]?

    /// Creates a new violation cluster.
    public init(
        ruleId: String,
        occurrenceCount: Int,
        affectedProjectCount: Int,
        dominantRootCause: String?,
        dominantFailedStep: FiveStepStage?,
        isRecurring: Bool,
        consecutiveAppearances: Int? = nil,
        priorOccurrenceCount: Int? = nil,
        priorProjectCount: Int? = nil,
        currentOccurrenceCount: Int? = nil,
        currentProjectCount: Int? = nil,
        affectedProjects: [String]? = nil,
        currentAffectedProjects: [String]? = nil
    ) {
        self.ruleId = ruleId
        self.occurrenceCount = occurrenceCount
        self.affectedProjectCount = affectedProjectCount
        self.dominantRootCause = dominantRootCause
        self.dominantFailedStep = dominantFailedStep
        self.isRecurring = isRecurring
        self.consecutiveAppearances = consecutiveAppearances
        self.priorOccurrenceCount = priorOccurrenceCount
        self.priorProjectCount = priorProjectCount
        self.currentOccurrenceCount = currentOccurrenceCount
        self.currentProjectCount = currentProjectCount
        self.affectedProjects = affectedProjects
        self.currentAffectedProjects = currentAffectedProjects
    }

    private enum CodingKeys: String, CodingKey {
        case ruleId, occurrenceCount, affectedProjectCount
        case dominantRootCause, dominantFailedStep, isRecurring
        case consecutiveAppearances
        case priorOccurrenceCount, priorProjectCount
        case currentOccurrenceCount, currentProjectCount
        case affectedProjects, currentAffectedProjects
    }

    /// Creates a violation cluster from a decoder, with backward-compatible optional fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ruleId = try container.decode(String.self, forKey: .ruleId)
        occurrenceCount = try container.decode(Int.self, forKey: .occurrenceCount)
        affectedProjectCount = try container.decode(Int.self, forKey: .affectedProjectCount)
        dominantRootCause = try container.decodeIfPresent(String.self, forKey: .dominantRootCause)
        dominantFailedStep = try container.decodeIfPresent(FiveStepStage.self, forKey: .dominantFailedStep)
        isRecurring = try container.decode(Bool.self, forKey: .isRecurring)
        consecutiveAppearances = try container.decodeIfPresent(Int.self, forKey: .consecutiveAppearances)
        priorOccurrenceCount = try container.decodeIfPresent(Int.self, forKey: .priorOccurrenceCount)
        priorProjectCount = try container.decodeIfPresent(Int.self, forKey: .priorProjectCount)
        currentOccurrenceCount = try container.decodeIfPresent(Int.self, forKey: .currentOccurrenceCount)
        currentProjectCount = try container.decodeIfPresent(Int.self, forKey: .currentProjectCount)
        affectedProjects = try container.decodeIfPresent([String].self, forKey: .affectedProjects)
        currentAffectedProjects = try container.decodeIfPresent([String].self, forKey: .currentAffectedProjects)
    }
}
