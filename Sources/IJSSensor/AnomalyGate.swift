import Foundation

/// Confidence level of an anomaly after gating by baseline validity.
public enum GatedSeverity: String, Sendable, Codable {
    /// Anomaly confirmed by a statistically valid baseline.
    case confirmed
    /// Anomaly is directional but based on a preliminary baseline.
    case directional
    /// Anomaly is unreliable due to insufficient baseline data.
    case unreliable
}

/// Recommended response action for a gated anomaly.
public enum Actionability: String, Sendable, Codable {
    /// Anomaly warrants immediate investigation.
    case investigate
    /// Anomaly should be monitored over subsequent windows.
    case monitor
    /// Action deferred due to low confidence or severity.
    case deferAction
    /// Anomaly explained by a known event; no action needed.
    case explained
}

/// Combines a statistical anomaly with validity-gated severity and actionability.
public struct AnomalyGate: Sendable, Codable, Equatable {
    /// The underlying statistical anomaly.
    public let anomaly: StatisticalAnomaly
    /// Severity after gating by baseline validity.
    public let gatedSeverity: GatedSeverity
    /// Recommended action based on gated severity.
    public let actionability: Actionability

    /// Creates an anomaly gate with explicit severity and actionability.
    public init(
        anomaly: StatisticalAnomaly,
        gatedSeverity: GatedSeverity,
        actionability: Actionability
    ) {
        self.anomaly = anomaly
        self.gatedSeverity = gatedSeverity
        self.actionability = actionability
    }

    /// Evaluates an anomaly against baseline validity to produce a gated assessment.
    public static func evaluate(
        anomaly: StatisticalAnomaly,
        baselineValidity: StatisticalValidity,
        isExplainedByKnownEvent: Bool = false
    ) -> AnomalyGate {
        let gatedSeverity: GatedSeverity
        var actionability: Actionability

        switch baselineValidity {
        case .valid:
            gatedSeverity = .confirmed
            switch anomaly.severity {
            case .extreme, .significant:
                actionability = .investigate
            case .notable:
                actionability = .monitor
            }
        case .preliminary:
            gatedSeverity = .directional
            switch anomaly.severity {
            case .extreme, .significant:
                actionability = .monitor
            case .notable:
                actionability = .deferAction
            }
        case .insufficient:
            gatedSeverity = .unreliable
            actionability = .deferAction
        }

        if isExplainedByKnownEvent {
            actionability = .explained
        }

        return AnomalyGate(
            anomaly: anomaly,
            gatedSeverity: gatedSeverity,
            actionability: actionability
        )
    }
}
