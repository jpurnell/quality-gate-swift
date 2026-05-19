import Testing
import Foundation
@testable import IJSDashboardCLI
@testable import IJSDashboardCore
import IJSSensor
import SwiftCLIKit

@Suite("PulseSectionRenderer")
struct PulseSectionRendererTests {

    // MARK: - Statistics

    @Test("renders gate run count and pass rate")
    func statisticsGateRuns() {
        let stats = makeStats(totalGateRuns: 100, passedRuns: 60, failedRuns: 40)
        let lines = PulseSectionRenderer.renderStatistics(stats, weekLabel: "2026-W20", width: 80)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("100"))
        #expect(joined.contains("60"))
    }

    @Test("renders override and calibration counts")
    func statisticsOverridesCalibrations() {
        let stats = makeStats(overrides: 5, calibrations: 2)
        let lines = PulseSectionRenderer.renderStatistics(stats, weekLabel: "2026-W20", width: 80)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("5"))
        #expect(joined.contains("2"))
    }

    @Test("renders week label")
    func statisticsWeekLabel() {
        let stats = makeStats()
        let lines = PulseSectionRenderer.renderStatistics(stats, weekLabel: "2026-W20", width: 80)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("2026-W20"))
    }

    @Test("renders consistency score when present")
    func statisticsConsistencyScore() {
        let stats = makeStats(consistencyScore: 0.85)
        let lines = PulseSectionRenderer.renderStatistics(stats, weekLabel: "2026-W20", width: 80)
        let joined = lines.joined(separator: "\n")
        #expect(joined.lowercased().contains("consistency") || joined.contains("0.85"))
    }

    // MARK: - Clusters

    @Test("renders cluster rule IDs and occurrence counts")
    func clustersRuleIDs() {
        let clusters = [
            ViolationCluster(ruleId: "force-unwrap", occurrenceCount: 50, affectedProjectCount: 10, dominantRootCause: nil, dominantFailedStep: nil, isRecurring: false),
        ]
        let lines = PulseSectionRenderer.renderClusters(clusters, width: 80)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("force-unwrap"))
        #expect(joined.contains("50"))
    }

    @Test("shows three-column table with prior, window, and current counts")
    func clustersThreeColumns() {
        let clusters = [
            ViolationCluster(
                ruleId: "force-unwrap", occurrenceCount: 50,
                affectedProjectCount: 10, dominantRootCause: nil,
                dominantFailedStep: nil, isRecurring: true,
                priorOccurrenceCount: 80, priorProjectCount: 15,
                currentOccurrenceCount: 30, currentProjectCount: 5
            ),
        ]
        let lines = PulseSectionRenderer.renderClusters(clusters, width: 100)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("Last Wk"))
        #expect(joined.contains("This Wk"))
        #expect(joined.contains("Current"))
        #expect(joined.contains("80x/15p"))
        #expect(joined.contains("50x/10p"))
        #expect(joined.contains("30x/5p"))
    }

    @Test("limits to top 5 clusters")
    func clustersTopFive() {
        let clusters = (0..<8).map {
            ViolationCluster(ruleId: "rule-\($0)", occurrenceCount: 10 - $0, affectedProjectCount: 1, dominantRootCause: nil, dominantFailedStep: nil, isRecurring: false)
        }
        let lines = PulseSectionRenderer.renderClusters(clusters, width: 80)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("rule-0"))
        #expect(joined.contains("rule-4"))
        #expect(!joined.contains("rule-5"))
    }

    @Test("returns empty for no clusters")
    func clustersEmpty() {
        let lines = PulseSectionRenderer.renderClusters([], width: 80)
        #expect(lines.isEmpty)
    }

    // MARK: - Anomalies

    @Test("renders anomaly metric and z-score")
    func anomalyMetric() {
        let anomalies = [
            StatisticalAnomaly(
                metric: "pass_rate", observedValue: 0.4, expectedValue: 0.7,
                zScore: -2.34, severity: .significant, date: Date(),
                scope: "corpus", direction: .negative, baselineValidity: .valid
            ),
        ]
        let lines = PulseSectionRenderer.renderAnomalies(anomalies, width: 80)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("pass_rate"))
        #expect(joined.contains("2.34"))
    }

    @Test("renders anomaly direction indicator")
    func anomalyDirection() {
        let anomalies = [
            StatisticalAnomaly(
                metric: "pass_rate", observedValue: 0.4, expectedValue: 0.7,
                zScore: -2.34, severity: .significant, date: Date(),
                scope: "corpus", direction: .negative, baselineValidity: .valid
            ),
        ]
        let lines = PulseSectionRenderer.renderAnomalies(anomalies, width: 80)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("\u{2193}") || joined.lowercased().contains("negative") || joined.contains("-"))
    }

    @Test("returns empty for no anomalies")
    func anomaliesEmpty() {
        let lines = PulseSectionRenderer.renderAnomalies([], width: 80)
        #expect(lines.isEmpty)
    }

    // MARK: - Narrative

    @Test("renders narrative text")
    func narrativeText() {
        let narrative = "This week's most urgent signal is a pass rate drop."
        let lines = PulseSectionRenderer.renderNarrative(narrative, width: 80)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("pass rate drop"))
    }

    @Test("handles nil narrative gracefully")
    func narrativeNil() {
        let lines = PulseSectionRenderer.renderNarrative(nil, width: 80)
        #expect(lines.isEmpty || lines.joined(separator: "\n").lowercased().contains("pending"))
    }

    // MARK: - Corpus Trend

    @Test("renders sparkline from daily snapshots")
    func corpusTrendSparkline() {
        let snapshots = (0..<7).map { day in
            DailySnapshot(
                date: Date(timeIntervalSince1970: Double(1747267200 + day * 86400)),
                scope: "corpus", gateRuns: 10, passedRuns: 6 + day, failedRuns: 4 - min(day, 4),
                overrides: 0, calibrations: 0, failuresByChecker: [:], overridesByRiskTier: [:]
            )
        }
        let lines = PulseSectionRenderer.renderCorpusTrend(snapshots, width: 80)
        let joined = lines.joined(separator: "\n")
        #expect(!joined.isEmpty)
        #expect(joined.lowercased().contains("trend"))
    }

    @Test("returns empty for no snapshots")
    func corpusTrendEmpty() {
        let lines = PulseSectionRenderer.renderCorpusTrend([], width: 80)
        #expect(lines.isEmpty)
    }

    // MARK: - Lines Fit Width

    @Test("all rendered lines fit within specified width")
    func linesRespectWidth() {
        let stats = makeStats(totalGateRuns: 100, passedRuns: 60, failedRuns: 40, overrides: 5, calibrations: 2)
        let clusters = [
            ViolationCluster(ruleId: "force-unwrap", occurrenceCount: 50, affectedProjectCount: 10, dominantRootCause: nil, dominantFailedStep: nil, isRecurring: true),
        ]
        let anomalies = [
            StatisticalAnomaly(
                metric: "pass_rate", observedValue: 0.4, expectedValue: 0.7,
                zScore: -2.34, severity: .significant, date: Date(),
                scope: "corpus", direction: .negative, baselineValidity: .valid
            ),
        ]
        let width = 80
        let allLines = PulseSectionRenderer.renderStatistics(stats, weekLabel: "2026-W20", width: width)
            + PulseSectionRenderer.renderClusters(clusters, width: width)
            + PulseSectionRenderer.renderAnomalies(anomalies, width: width)
            + PulseSectionRenderer.renderNarrative("A short narrative.", width: width)

        for (idx, line) in allLines.enumerated() {
            let visLen = ANSIStringMetrics.visibleLength(line)
            #expect(visLen <= width, "Line \(idx) visible length \(visLen) exceeds width \(width)")
        }
    }
}

// MARK: - Helpers

private func makeStats(
    totalGateRuns: Int = 100,
    passedRuns: Int = 60,
    failedRuns: Int = 40,
    overrides: Int = 5,
    calibrations: Int = 2,
    consistencyScore: Double? = 0.85
) -> PulseStatistics {
    PulseStatistics(
        totalGateRuns: totalGateRuns,
        passedRuns: passedRuns,
        failedRuns: failedRuns,
        totalOverrides: overrides,
        totalCalibrations: calibrations,
        overridesByRiskTier: [:],
        failuresByChecker: ["safety": 25, "doc-coverage": 15],
        rootCauseDistribution: [:],
        failedStepDistribution: [:],
        meanConsistencyScore: consistencyScore,
        corpusTrends: [],
        projectTrends: [:],
        anomalies: [],
        corpusSnapshots: [],
        projectSnapshots: [:]
    )
}
