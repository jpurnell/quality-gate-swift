import Foundation
import CorpusKit
@testable import NarrativeCore

/// Deterministic pulse fixtures for NarrativeCore tests. All dates are fixed
/// epochs so output is reproducible.
enum PulseFixtures {
    static func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    static func emptyStats(
        weightedScores: [String: Double]? = nil,
        gatedAnomalies: [AnomalyGate]? = nil
    ) -> PulseStatistics {
        PulseStatistics(
            totalGateRuns: 0,
            passedRuns: 0,
            failedRuns: 0,
            totalOverrides: 0,
            totalCalibrations: 0,
            corpusTrends: [],
            projectTrends: [:],
            anomalies: [],
            weightedScores: weightedScores,
            gatedAnomalies: gatedAnomalies
        )
    }

    static func pulse(
        projects: [String] = [],
        statistics: PulseStatistics? = nil,
        narrative: String? = nil,
        projectTiers: [String: ProjectTier]? = nil,
        projectTrajectories: [ProjectTrajectory]? = nil,
        currentSnapshot: CurrentSnapshot? = nil
    ) -> InstitutionalPulse {
        InstitutionalPulse(
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 86_400),
            weekLabel: "2026-W30",
            label: "2026-07-29",
            projects: projects,
            statistics: statistics ?? emptyStats(),
            violationClusters: [],
            proposedPolicyUpdates: [],
            calibrationSummaries: [],
            narrative: narrative,
            generatedAt: Date(timeIntervalSince1970: 86_400),
            projectTiers: projectTiers,
            projectTrajectories: projectTrajectories,
            currentSnapshot: currentSnapshot
        )
    }

    static func status(
        _ id: String,
        passing: Bool = true,
        failedCheckers: [String] = [],
        overrideCount: Int = 0
    ) -> CurrentSnapshot.ProjectStatus {
        CurrentSnapshot.ProjectStatus(
            projectID: id,
            allPassed: passing,
            failedCheckers: failedCheckers,
            lastRunDate: day("2026-07-28"),
            overrideCount: overrideCount
        )
    }

    static func anomaly(
        scope: String,
        metric: String = "passRate",
        z: Double = 3.5,
        severity: GatedSeverity = .confirmed,
        actionability: Actionability = .investigate
    ) -> AnomalyGate {
        AnomalyGate(
            anomaly: StatisticalAnomaly(
                metric: metric,
                observedValue: 0.5,
                expectedValue: 0.04,
                zScore: z,
                severity: .extreme,
                date: day("2026-07-20"),
                scope: scope,
                direction: .positive,
                baselineValidity: .valid
            ),
            gatedSeverity: severity,
            actionability: actionability
        )
    }
}
