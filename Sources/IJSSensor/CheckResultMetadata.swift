import Foundation
import QualityGateTypes

/// Ethical risk signals detected by the quality gate's automated auditors.
public enum EthicalFlag: String, Sendable, Codable {
    /// Data collection without meaningful user consent.
    case unauthorizedDataCollection // LIVE: domain taxonomy for ethical audit findings
    /// UI patterns designed to trick users into unintended actions.
    case manipulativeUX // LIVE: domain taxonomy for ethical audit findings
    /// Data transmission code missing a required consent guard.
    case missingConsentGuard // LIVE: domain taxonomy for ethical audit findings
    /// Automated decision-making that legally requires human-in-the-loop.
    case automatedDecisionRequiringHumanReview // LIVE: domain taxonomy for ethical audit findings
    /// Features that track or monitor users without disclosure.
    case surveillanceFeature // LIVE: domain taxonomy for ethical audit findings
}

/// Where the quality gate was executed.
public enum Environment: String, Sendable, Codable {
    /// Developer's local machine.
    case local
    /// Continuous integration pipeline.
    case ci
}

/// An override enriched with IJS judgment context.
///
/// Wraps a `DiagnosticOverride` from the quality gate with institutional
/// metadata: who authorized it, at what risk tier, and with what authority.
public struct OverrideRecord: Sendable, Codable, Equatable {
    /// The underlying diagnostic override from the quality gate.
    public let diagnosticOverride: DiagnosticOverride
    /// The practitioner or stakeholder who authorized the override.
    public let author: String
    /// The risk tier of the overridden rule.
    public let riskTier: RiskTier
    /// The authority level of the person approving the override.
    public let authorityLevel: AuthorityLevel

    /// Creates a new override record.
    /// - Parameters:
    ///   - diagnosticOverride: The underlying diagnostic override from the quality gate.
    ///   - author: The practitioner who authorized the override.
    ///   - riskTier: The risk tier of the overridden rule.
    ///   - authorityLevel: The authority level of the approver.
    public init(
        diagnosticOverride: DiagnosticOverride,
        author: String,
        riskTier: RiskTier,
        authorityLevel: AuthorityLevel
    ) {
        self.diagnosticOverride = diagnosticOverride
        self.author = author
        self.riskTier = riskTier
        self.authorityLevel = authorityLevel
    }
}

/// Extended quality gate result with judgment system fields.
///
/// Bridges the gap between technical pass/fail status and human discernment
/// by capturing decision ownership, override rationale, ethical flags, and
/// institutional consistency scoring alongside standard checker results.
public struct CheckResultMetadata: Sendable, Codable, Equatable {
    /// Repository or project identifier.
    public let projectID: String
    /// When the quality gate was executed.
    public let timestamp: Date
    /// Whether the gate ran locally or in CI.
    public let environment: Environment
    /// The stakeholder with authority to ship this artifact, per the DRM.
    public let decisionOwner: String
    /// Results from each quality gate checker.
    public let results: [CheckResult]
    /// Documented overrides of quality gate checks, enriched with judgment context.
    public let overrides: [OverrideRecord]
    /// The overall risk classification for this gate run.
    public let riskTier: RiskTier
    /// Ethical risk signals detected by automated auditors.
    public let ethicalFlags: [EthicalFlag]
    /// How consistent this implementation is with institutional lessons. Nil if not yet scored.
    public let consistencyScore: Double?
    /// Total compliance annotations verified across all checkers (not overrides).
    public let complianceCount: Int

    /// Creates a new check result metadata record.
    /// - Parameters:
    ///   - projectID: Repository or project identifier.
    ///   - timestamp: When the gate was executed.
    ///   - environment: Local or CI.
    ///   - decisionOwner: Stakeholder with shipping authority.
    ///   - results: Results from each checker.
    ///   - overrides: Documented overrides with judgment context.
    ///   - riskTier: Overall risk classification.
    ///   - ethicalFlags: Ethical risk signals.
    ///   - consistencyScore: Institutional consistency score, if available.
    ///   - complianceCount: Total compliance annotations verified.
    public init(
        projectID: String,
        timestamp: Date,
        environment: Environment,
        decisionOwner: String,
        results: [CheckResult],
        overrides: [OverrideRecord],
        riskTier: RiskTier,
        ethicalFlags: [EthicalFlag],
        consistencyScore: Double?,
        complianceCount: Int = 0
    ) {
        self.projectID = projectID
        self.timestamp = timestamp
        self.environment = environment
        self.decisionOwner = decisionOwner
        self.results = results
        self.overrides = overrides
        self.riskTier = riskTier
        self.ethicalFlags = ethicalFlags
        self.consistencyScore = consistencyScore
        self.complianceCount = complianceCount
    }

    /// Decodes a ``CheckResultMetadata`` from an external representation, defaulting `complianceCount` to `0` when absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        environment = try container.decode(Environment.self, forKey: .environment)
        decisionOwner = try container.decode(String.self, forKey: .decisionOwner)
        results = try container.decode([CheckResult].self, forKey: .results)
        overrides = try container.decode([OverrideRecord].self, forKey: .overrides)
        riskTier = try container.decode(RiskTier.self, forKey: .riskTier)
        ethicalFlags = try container.decode([EthicalFlag].self, forKey: .ethicalFlags)
        consistencyScore = try container.decodeIfPresent(Double.self, forKey: .consistencyScore)
        complianceCount = try container.decodeIfPresent(Int.self, forKey: .complianceCount) ?? 0
    }
}
