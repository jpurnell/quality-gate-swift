import Foundation
import BusinessMath
import IJSSensor
import IJSAggregator

/// Orchestrates Pulse generation from corpus telemetry with statistical analysis.
///
/// The Refiner is purely computational — it reads corpus data via TelemetryWriter
/// and produces model objects. It performs no file I/O directly.
public actor PulseRefiner {

    private let writer: TelemetryWriter

    /// Creates a new pulse refiner.
    /// - Parameter writer: The telemetry writer for corpus I/O.
    public init(writer: TelemetryWriter) {
        self.writer = writer
    }

    /// Generates an InstitutionalPulse with full statistical analysis.
    public func refine(
        from corpusPaths: [CorpusPath],
        windowStart: Date,
        windowEnd: Date,
        previousPulse: InstitutionalPulse?,
        lookbackDays: Int = 90,
        manifest: CorpusManifest? = nil,
        label: String? = nil
    ) async throws -> InstitutionalPulse {
        let lookbackStart = Calendar.current.date(
            byAdding: .day, value: -lookbackDays, to: windowStart
        ) ?? windowStart

        var allWindowMetadata: [CheckResultMetadata] = []
        var allWindowCalibrations: [JudgmentCalibration] = []
        var allBaselineMetadata: [CheckResultMetadata] = []
        var projectSnapshots: [String: [DailySnapshot]] = [:]
        var projectTrends: [String: [TrendAnalysis]] = [:]

        for corpus in corpusPaths {
            let windowMeta = try await writer.readMetadata(
                from: corpus, startDate: windowStart, endDate: windowEnd
            )
            let windowCal = try await writer.readCalibrations(
                from: corpus, startDate: windowStart, endDate: windowEnd
            )
            let baselineMeta = try await writer.readMetadata(
                from: corpus, startDate: lookbackStart, endDate: windowStart
            )

            allWindowMetadata.append(contentsOf: windowMeta)
            allWindowCalibrations.append(contentsOf: windowCal)
            allBaselineMetadata.append(contentsOf: baselineMeta)

            let projWindowSnapshots = buildSnapshots(from: windowMeta, scope: corpus.projectID)
            projectSnapshots[corpus.projectID] = projWindowSnapshots

            let allProjectMeta = baselineMeta + windowMeta
            let allProjectSnapshots = buildSnapshots(from: allProjectMeta, scope: corpus.projectID)
            let trends = analyzeTrends(from: allProjectSnapshots)
            projectTrends[corpus.projectID] = trends
        }

        let allMeta = allBaselineMetadata + allWindowMetadata
        let corpusSnapshots = buildSnapshots(from: allMeta, scope: "corpus")
        let corpusTrends = analyzeTrends(from: corpusSnapshots)

        let windowCorpusSnapshots = buildSnapshots(from: allWindowMetadata, scope: "corpus")

        var allAnomalies: [StatisticalAnomaly] = []
        for (projectID, windowSnaps) in projectSnapshots {
            if let trends = projectTrends[projectID] {
                let anomalies = detectAnomalies(
                    windowSnapshots: windowSnaps,
                    baselineTrends: trends
                )
                allAnomalies.append(contentsOf: anomalies)
            }
        }
        let corpusAnomalies = detectAnomalies(
            windowSnapshots: windowCorpusSnapshots,
            baselineTrends: corpusTrends
        )
        allAnomalies.append(contentsOf: corpusAnomalies)

        let previousClusters = previousPulse?.violationClusters ?? []
        var clusters = detectClusters(
            from: allWindowMetadata,
            calibrations: allWindowCalibrations,
            previousClusters: previousClusters
        )

        var allComplexityReports: [ComplexityReport] = []
        var projectComplexityReports: [String: [ComplexityReport]] = [:]
        for corpus in corpusPaths {
            let reports = (try? await writer.readComplexityReports( // silent: complexity reports may not exist yet
                from: corpus, startDate: lookbackStart, endDate: windowEnd
            )) ?? []
            allComplexityReports.append(contentsOf: reports)
            if !reports.isEmpty {
                projectComplexityReports[corpus.projectID] = reports
            }
        }

        let complexityClusters = detectComplexityClusters(
            from: allComplexityReports,
            previousClusters: previousClusters
        )
        clusters.append(contentsOf: complexityClusters)
        clusters.sort { $0.occurrenceCount > $1.occurrenceCount }

        let complexityTrends: [ComplexityTrend]?
        if allComplexityReports.isEmpty {
            complexityTrends = nil
        } else {
            let windowReports = allComplexityReports.filter { $0.timestamp >= windowStart }
            let baselineReports = allComplexityReports.filter { $0.timestamp < windowStart }
            let scope = corpusPaths.count == 1 ? corpusPaths[0].projectID : "corpus"
            var trends = buildComplexityTrends(
                windowReports: windowReports,
                baselineReports: baselineReports,
                scope: scope
            )

            let crossProjectPatterns = detectCrossProjectPatterns(
                projectReports: projectComplexityReports
            )
            if !crossProjectPatterns.isEmpty, var enriched = trends {
                for i in enriched.indices {
                    enriched[i] = ComplexityTrend(
                        metricName: enriched[i].metricName,
                        trend: enriched[i].trend,
                        topDriftingModules: enriched[i].topDriftingModules,
                        emergingPatterns: enriched[i].emergingPatterns + crossProjectPatterns.filter {
                            !enriched[i].emergingPatterns.contains($0)
                        },
                        resolvedPatterns: enriched[i].resolvedPatterns
                    )
                }
                trends = enriched
            }

            complexityTrends = trends
        }

        // Build per-project metadata dict for weighted scoring, filtering out
        // partial runs and deduplicating to one run per calendar day
        let projectMetadataByProject = filterMetadataForScoring(
            Dictionary(grouping: allWindowMetadata, by: \.projectID)
        )

        // Tier classification
        let tiers = classifyProjects(projectSnapshots: projectSnapshots, windowEnd: windowEnd)

        // Weighted scores
        let weightedScores = computeWeightedScores(projectMetadata: projectMetadataByProject)

        // Trajectories
        let trajectories = computeTrajectories(
            projectWeightedScores: weightedScores,
            projectSnapshots: projectSnapshots,
            projectMetadata: projectMetadataByProject
        )

        // Anomaly gating
        let gatedAnomalies = allAnomalies.map { anomaly in
            AnomalyGate.evaluate(
                anomaly: anomaly,
                baselineValidity: anomaly.baselineValidity
            )
        }

        // Group snapshots
        let groupSnaps = computeGroupSnapshots(
            projectSnapshots: projectSnapshots,
            groups: manifest?.groups ?? [:]
        )

        let statistics = buildStatistics(
            windowMetadata: allWindowMetadata,
            calibrations: allWindowCalibrations,
            corpusTrends: corpusTrends,
            projectTrends: projectTrends,
            anomalies: allAnomalies,
            corpusSnapshots: windowCorpusSnapshots,
            projectSnapshots: projectSnapshots,
            complexityTrends: complexityTrends,
            weightedScores: weightedScores.isEmpty ? nil : weightedScores,
            gatedAnomalies: gatedAnomalies.isEmpty ? nil : gatedAnomalies
        )

        let weekLabel = isoWeekLabel(for: windowStart)

        return InstitutionalPulse(
            windowStart: windowStart,
            windowEnd: windowEnd,
            weekLabel: weekLabel,
            label: label,
            projects: corpusPaths.map(\.projectID),
            statistics: statistics,
            violationClusters: clusters,
            proposedPolicyUpdates: allWindowCalibrations.compactMap(\.proposedPolicyUpdate),
            calibrationSummaries: allWindowCalibrations.map(\.pulseContribution),
            narrative: nil,
            generatedAt: Date(),
            projectTiers: tiers.isEmpty ? nil : tiers,
            projectTrajectories: trajectories.isEmpty ? nil : trajectories,
            groupSnapshots: groupSnaps.isEmpty ? nil : groupSnaps
        )
    }

    /// Builds DailySnapshots from metadata, grouped by date and scope.
    public func buildSnapshots(
        from metadata: [CheckResultMetadata],
        scope: String
    ) -> [DailySnapshot] {
        guard !metadata.isEmpty else { return [] }

        let calendar = Calendar.current
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let grouped = Dictionary(grouping: metadata) { meta -> DateComponents in
            utcCalendar.dateComponents([.year, .month, .day], from: meta.timestamp)
        }

        return grouped.compactMap { (components, records) -> DailySnapshot? in
            guard let date = utcCalendar.date(from: components) else { return nil }

            let gateRuns = records.count
            let passedRuns = records.filter { meta in
                meta.results.allSatisfy { $0.status == .passed }
            }.count
            let failedRuns = gateRuns - passedRuns
            let overrides = records.reduce(0) { $0 + $1.overrides.count }
            let calibrationCount = 0

            var failuresByChecker: [String: Int] = [:]
            for meta in records {
                for result in meta.results where result.status == .failed {
                    failuresByChecker[result.checkerId, default: 0] += 1
                }
            }

            var overridesByRiskTier: [RiskTier: Int] = [:]
            for meta in records {
                for override in meta.overrides {
                    overridesByRiskTier[override.riskTier, default: 0] += 1
                }
            }

            return DailySnapshot(
                date: date,
                scope: scope,
                gateRuns: gateRuns,
                passedRuns: passedRuns,
                failedRuns: failedRuns,
                overrides: overrides,
                calibrations: calibrationCount,
                failuresByChecker: failuresByChecker,
                overridesByRiskTier: overridesByRiskTier
            )
        }.sorted { $0.date < $1.date }
    }

    /// Computes trend analyses for a set of daily snapshots.
    public func analyzeTrends(
        from snapshots: [DailySnapshot]
    ) -> [TrendAnalysis] {
        guard snapshots.count >= 3 else { return [] }

        let metrics: [(String, (DailySnapshot) -> Double)] = [
            ("passRate", \.passRate),
            ("failureRate", \.failureRate),
            ("overrideRate", \.overrideRate),
            ("calibrationRate", \.calibrationRate),
        ]

        return metrics.compactMap { (name, extractor) in
            let values = snapshots.map(extractor)
            return TrendAnalysis.compute(metric: name, values: values)
        }
    }

    /// Detects statistical anomalies by comparing window snapshots against baseline trends.
    public func detectAnomalies(
        windowSnapshots: [DailySnapshot],
        baselineTrends: [TrendAnalysis],
        threshold: Double = 1.645
    ) -> [StatisticalAnomaly] {
        guard !windowSnapshots.isEmpty, !baselineTrends.isEmpty else { return [] }

        let metricExtractors: [String: (DailySnapshot) -> Double] = [
            "passRate": \.passRate,
            "failureRate": \.failureRate,
            "overrideRate": \.overrideRate,
            "calibrationRate": \.calibrationRate,
        ]

        let positiveMetrics: Set<String> = ["passRate"]

        var anomalies: [StatisticalAnomaly] = []

        for trend in baselineTrends {
            guard trend.standardDeviation > 0,
                  let extractor = metricExtractors[trend.metric] else { continue }

            for snapshot in windowSnapshots {
                let observed = extractor(snapshot)
                let z = BusinessMath.standardize(x: observed, mean: trend.mean, stdev: trend.standardDeviation)
                let absZ = abs(z)

                guard absZ >= threshold else { continue }

                let severity: IJSSensor.AnomalySeverity
                if absZ >= 3.0 {
                    severity = .extreme
                } else if absZ >= 1.96 {
                    severity = .significant
                } else {
                    severity = .notable
                }

                let isPositiveMetric = positiveMetrics.contains(trend.metric)
                let direction: AnomalyDirection
                if isPositiveMetric {
                    direction = z > 0 ? .positive : .negative
                } else {
                    direction = z > 0 ? .negative : .positive
                }

                anomalies.append(StatisticalAnomaly(
                    metric: trend.metric,
                    observedValue: observed,
                    expectedValue: trend.mean,
                    zScore: z,
                    severity: severity,
                    date: snapshot.date,
                    scope: snapshot.scope,
                    direction: direction,
                    baselineValidity: trend.validity
                ))
            }
        }

        return anomalies
    }

    /// Detects violation clusters and marks recurring patterns.
    public func detectClusters(
        from metadata: [CheckResultMetadata],
        calibrations: [JudgmentCalibration],
        previousClusters: [ViolationCluster]
    ) -> [ViolationCluster] {
        var ruleOccurrences: [String: Int] = [:]
        var ruleProjects: [String: Set<String>] = [:]

        for meta in metadata {
            for result in meta.results where result.status == .failed {
                for diagnostic in result.diagnostics {
                    guard let ruleId = diagnostic.ruleId else { continue }
                    ruleOccurrences[ruleId, default: 0] += 1
                    ruleProjects[ruleId, default: []].insert(meta.projectID)
                }
            }
        }

        let previousRuleIds = Set(previousClusters.map(\.ruleId))

        var rootCauseCounts: [String: Int] = [:]
        var failedStepCounts: [FiveStepStage: Int] = [:]
        for cal in calibrations {
            rootCauseCounts[cal.rootCauseAnalysis.rootCause, default: 0] += 1
            failedStepCounts[cal.rootCauseAnalysis.failedStep, default: 0] += 1
        }

        let dominantRootCause = rootCauseCounts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .first?.key
        let dominantFailedStep = failedStepCounts
            .sorted { $0.value > $1.value }
            .first?.key

        return ruleOccurrences
            .filter { $0.value >= 2 }
            .map { (ruleId, count) in
                ViolationCluster(
                    ruleId: ruleId,
                    occurrenceCount: count,
                    affectedProjectCount: ruleProjects[ruleId]?.count ?? 0,
                    dominantRootCause: dominantRootCause,
                    dominantFailedStep: dominantFailedStep,
                    isRecurring: previousRuleIds.contains(ruleId)
                )
            }
            .sorted { $0.occurrenceCount > $1.occurrenceCount }
    }

    // MARK: - Private Helpers

    private func buildStatistics(
        windowMetadata: [CheckResultMetadata],
        calibrations: [JudgmentCalibration],
        corpusTrends: [TrendAnalysis],
        projectTrends: [String: [TrendAnalysis]],
        anomalies: [StatisticalAnomaly],
        corpusSnapshots: [DailySnapshot],
        projectSnapshots: [String: [DailySnapshot]],
        complexityTrends: [ComplexityTrend]? = nil,
        weightedScores: [String: Double]? = nil,
        gatedAnomalies: [AnomalyGate]? = nil
    ) -> PulseStatistics {
        let totalGateRuns = windowMetadata.count
        let passedRuns = windowMetadata.filter { meta in
            meta.results.allSatisfy { $0.status == .passed }
        }.count
        let failedRuns = totalGateRuns - passedRuns
        let totalOverrides = windowMetadata.reduce(0) { $0 + $1.overrides.count }

        var overridesByRiskTier: [RiskTier: Int] = [:]
        for meta in windowMetadata {
            for override in meta.overrides {
                overridesByRiskTier[override.riskTier, default: 0] += 1
            }
        }

        var failuresByChecker: [String: Int] = [:]
        for meta in windowMetadata {
            for result in meta.results where result.status == .failed {
                failuresByChecker[result.checkerId, default: 0] += 1
            }
        }

        var rootCauseDistribution: [String: Int] = [:]
        var failedStepDistribution: [FiveStepStage: Int] = [:]
        for cal in calibrations {
            rootCauseDistribution[cal.rootCauseAnalysis.rootCause, default: 0] += 1
            failedStepDistribution[cal.rootCauseAnalysis.failedStep, default: 0] += 1
        }

        let consistencyScores = windowMetadata.compactMap(\.consistencyScore)
        let meanConsistencyScore: Double? = consistencyScores.isEmpty // fp-safety:disable guarded by isEmpty
            ? nil
            : consistencyScores.reduce(0, +) / Double(consistencyScores.count)

        return PulseStatistics(
            totalGateRuns: totalGateRuns,
            passedRuns: passedRuns,
            failedRuns: failedRuns,
            totalOverrides: totalOverrides,
            totalCalibrations: calibrations.count,
            overridesByRiskTier: overridesByRiskTier,
            failuresByChecker: failuresByChecker,
            rootCauseDistribution: rootCauseDistribution,
            failedStepDistribution: failedStepDistribution,
            meanConsistencyScore: meanConsistencyScore,
            corpusTrends: corpusTrends,
            projectTrends: projectTrends,
            anomalies: anomalies,
            corpusSnapshots: corpusSnapshots,
            projectSnapshots: projectSnapshots,
            complexityTrends: complexityTrends,
            weightedScores: weightedScores,
            gatedAnomalies: gatedAnomalies
        )
    }

    private func isoWeekLabel(for date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let year = calendar.component(.yearForWeekOfYear, from: date)
        let week = calendar.component(.weekOfYear, from: date)
        let yearStr = "\(year)"
        let weekStr = week < 10 ? "0\(week)" : "\(week)"
        return "\(yearStr)-W\(weekStr)"
    }
}
