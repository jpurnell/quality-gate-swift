import Foundation
import IJSSensor
import QualityGateTypes

/// Classifies diagnostic overrides into judgment calibrations by matching justification text to root cause categories.
public enum CalibrationClassifier: Sendable {

    /// Generates ``JudgmentCalibration`` records from diagnostic overrides using keyword-based root cause classification.
    public static func classify(
        overrides: [DiagnosticOverride],
        decisionOwner: String,
        practitioner: String,
        riskTier: RiskTier,
        timestamp: Date
    ) -> [JudgmentCalibration] {
        overrides.map { override in
            let category = classifyJustification(cleanJustification(override.justification))
            let analysis = buildAnalysis(for: category, override: override)
            let location = override.filePath ?? "unknown file"

            return JudgmentCalibration(
                date: timestamp,
                decisionOwner: decisionOwner,
                practitioner: practitioner,
                riskTier: riskTier,
                rootCauseAnalysis: analysis,
                redTeamDissent: "If this \(category.label) classification is wrong, the suppressed \(override.ruleId) violation could mask a real defect in \(location).",
                proposedPolicyUpdate: nil,
                pulseContribution: "Auto-classified \(override.ruleId) override as \(category.label) in \(location). \(truncate(override.justification, to: 120))"
            )
        }
    }

    // MARK: - Classification

    private enum Category {
        case falsePositive
        case designConstraint
        case deferred
        case thirdParty
        case acceptableRisk
        case unclassified

        var label: String {
            switch self {
            case .falsePositive: "false-positive"
            case .designConstraint: "design-constraint"
            case .deferred: "deferred"
            case .thirdParty: "third-party"
            case .acceptableRisk: "acceptable-risk"
            case .unclassified: "unclassified"
            }
        }

        var rootCause: String {
            switch self {
            case .falsePositive: "imprecise"
            case .designConstraint: "structural"
            case .deferred: "deferred"
            case .thirdParty: "external"
            case .acceptableRisk: "expedient"
            case .unclassified: "unclassified"
            }
        }

        var failedStep: FiveStepStage {
            switch self {
            case .falsePositive: .diagnosis
            case .designConstraint: .design
            case .deferred: .doing
            case .thirdParty: .design
            case .acceptableRisk: .diagnosis
            case .unclassified: .diagnosis
            }
        }
    }

    private static let patternGroups: [(keywords: [String], category: Category)] = [
        (["constant", "hardcoded", "literal", "validated", "guaranteed",
          "can't fail", "always", "never nil", "reject"], .falsePositive),
        (["cli", "user-facing", "by design", "required by", "protocol",
          "architecture", "structural", "skipped"], .designConstraint),
        (["todo", "tracked", "will fix", "temporary", "workaround", "defer"], .deferred),
        (["external", "third-party", "upstream", "dependency"], .thirdParty),
        (["accept", "acknowledged", "risk", "tradeoff"], .acceptableRisk),
    ]

    private static func classifyJustification(_ text: String) -> Category {
        let lowered = text.lowercased()
        for group in patternGroups {
            for keyword in group.keywords {
                if lowered.contains(keyword) {
                    return group.category
                }
            }
        }
        return .unclassified
    }

    // MARK: - Analysis builders

    private static func buildAnalysis(
        for category: Category,
        override: DiagnosticOverride
    ) -> RootCauseAnalysis {
        let cleaned = cleanJustification(override.justification)
        return RootCauseAnalysis(
            proximateCause: "Override of \(override.ruleId): \(truncate(cleaned, to: 100))",
            chainOfInquiry: [cleaned],
            rootCause: category.rootCause,
            failedStep: category.failedStep,
            isRecurringPattern: false
        )
    }

    private static func cleanJustification(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        let prefixes = ["// ", "SAFETY: ", "SAFETY:", "silent: ", "silent:",
                        "Justification: ", "Justification:"]
        for prefix in prefixes {
            if result.hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    private static func truncate(_ text: String, to maxLength: Int) -> String {
        if text.count <= maxLength { return text }
        return String(text.prefix(maxLength - 3)) + "..."
    }
}
