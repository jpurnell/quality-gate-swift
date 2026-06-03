import Foundation
import IJSSensor
import QualityGateTypes

/// Computes calibration status and coverage reports from corpus telemetry.
public enum CalibrationReport: Sendable {

    /// Per-rule override and calibration counts for --status mode.
    public struct RuleStatus: Sendable, Equatable {
        /// The diagnostic rule identifier.
        public let ruleId: String
        /// Number of overrides recorded for this rule.
        public let overrideCount: Int
        /// Number of calibrations generated for this rule.
        public let calibratedCount: Int
        /// Number of calibrations classified as unclassified (needs manual review).
        public let unclassifiedCount: Int
    }

    /// Per-checker sample count and false-positive rate for --coverage mode.
    public struct CheckerCoverage: Sendable, Equatable {
        /// Checker identifier (prefix before the first dot in rule IDs).
        public let checkerId: String
        /// Number of gate runs that included this checker.
        public let sampleCount: Int
        /// Statistical reliability based on sample count.
        public let validity: StatisticalValidity
        /// Number of calibration records for rules in this checker.
        public let calibrationCount: Int
        /// Fraction of calibrations classified as false-positive, or nil when no calibrations exist.
        public let falsePositiveRate: Double?
    }

    /// Computes per-rule override/calibration status.
    public static func status(
        metadata: [CheckResultMetadata],
        calibrations: [JudgmentCalibration]
    ) -> [RuleStatus] {
        var overrideCounts: [String: Int] = [:]
        for entry in metadata {
            for override in entry.overrides {
                let rule = override.diagnosticOverride.ruleId
                overrideCounts[rule, default: 0] += 1
            }
        }

        var calibratedCounts: [String: Int] = [:]
        var unclassifiedCounts: [String: Int] = [:]
        for calibration in calibrations {
            guard let rule = extractRuleId(from: calibration) else { continue }
            calibratedCounts[rule, default: 0] += 1
            if calibration.rootCauseAnalysis.rootCause == "unclassified" {
                unclassifiedCounts[rule, default: 0] += 1
            }
        }

        let allRuleIds = Set(overrideCounts.keys)
            .union(calibratedCounts.keys)

        return allRuleIds.map { rule in
            RuleStatus(
                ruleId: rule,
                overrideCount: overrideCounts[rule, default: 0],
                calibratedCount: calibratedCounts[rule, default: 0],
                unclassifiedCount: unclassifiedCounts[rule, default: 0]
            )
        }.sorted { $0.ruleId < $1.ruleId }
    }

    /// Computes per-checker sample counts and false-positive rates.
    public static func coverage(
        metadata: [CheckResultMetadata],
        calibrations: [JudgmentCalibration]
    ) -> [CheckerCoverage] {
        var sampleCounts: [String: Int] = [:]
        for entry in metadata {
            var seenCheckers: Set<String> = []
            for result in entry.results {
                seenCheckers.insert(result.checkerId)
            }
            for checker in seenCheckers {
                sampleCounts[checker, default: 0] += 1
            }
        }

        var calibrationCounts: [String: Int] = [:]
        var fpCounts: [String: Int] = [:]
        for calibration in calibrations {
            guard let ruleId = extractRuleId(from: calibration) else { continue }
            let checker = checkerPrefix(from: ruleId)
            calibrationCounts[checker, default: 0] += 1
            if calibration.rootCauseAnalysis.rootCause == "imprecise" {
                fpCounts[checker, default: 0] += 1
            }
        }

        return sampleCounts.map { checker, count in
            let calCount = calibrationCounts[checker, default: 0]
            let fpRate: Double?
            let divisor = Double(calCount)
            guard divisor > 0 else {
                fpRate = nil
                return CheckerCoverage(
                    checkerId: checker,
                    sampleCount: count,
                    validity: StatisticalValidity.from(sampleSize: count),
                    calibrationCount: calCount,
                    falsePositiveRate: nil
                )
            }
            fpRate = Double(fpCounts[checker, default: 0]) / divisor
            return CheckerCoverage(
                checkerId: checker,
                sampleCount: count,
                validity: StatisticalValidity.from(sampleSize: count),
                calibrationCount: calCount,
                falsePositiveRate: fpRate
            )
        }.sorted { $0.checkerId < $1.checkerId }
    }

    // MARK: - Helpers

    private static func extractRuleId(from calibration: JudgmentCalibration) -> String? {
        let prefix = "Override of "
        let cause = calibration.rootCauseAnalysis.proximateCause
        guard cause.hasPrefix(prefix) else { return nil }
        let rest = String(cause.dropFirst(prefix.count))
        guard let colonIndex = rest.firstIndex(of: ":") else { return nil }
        return String(rest[rest.startIndex..<colonIndex])
    }

    private static func checkerPrefix(from ruleId: String) -> String {
        guard let dotIndex = ruleId.firstIndex(of: ".") else { return ruleId }
        return String(ruleId[ruleId.startIndex..<dotIndex])
    }
}
