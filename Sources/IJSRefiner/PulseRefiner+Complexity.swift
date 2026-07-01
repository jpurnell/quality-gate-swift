import Foundation
import IJSSensor
import IJSAggregator

extension PulseRefiner {

    /// Builds ComplexitySnapshots from complexity reports, one per day.
    ///
    /// When multiple reports exist for the same day, uses the latest one.
    public func buildComplexitySnapshots(
        from reports: [ComplexityReport],
        scope: String
    ) -> [ComplexitySnapshot] {
        guard !reports.isEmpty else { return [] }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")

        let grouped = Dictionary(grouping: reports) { report in
            dayFormatter.string(from: report.timestamp)
        }

        return grouped.map { (day, dayReports) in
            let latest = dayReports.max { $0.timestamp < $1.timestamp } ?? dayReports[0]
            let distribution = latest.summary.complexityDistribution
            let dominantBigO = distribution.max { $0.value < $1.value }?.key ?? "O(1)"

            return ComplexitySnapshot(
                date: day,
                scope: scope,
                medianCognitive: latest.summary.medianCognitive,
                p90Cognitive: latest.summary.p90Cognitive,
                maxCognitive: latest.summary.maxCognitive,
                totalPatterns: latest.summary.totalPatterns,
                functionsAboveThreshold: latest.summary.functionsAboveThreshold,
                dominantBigO: dominantBigO
            )
        }.sorted { $0.date < $1.date }
    }

    /// Computes ComplexityTrend analyses from a series of snapshots.
    ///
    /// Produces trends for: medianCognitive, p90Cognitive, totalPatterns.
    public func analyzeComplexityTrends(
        from snapshots: [ComplexitySnapshot]
    ) -> [ComplexityTrend] {
        guard snapshots.count >= 3 else { return [] }

        let metrics: [(String, (ComplexitySnapshot) -> Double)] = [
            ("medianCognitive", { Double($0.medianCognitive) }),
            ("p90Cognitive", { Double($0.p90Cognitive) }),
            ("totalPatterns", { Double($0.totalPatterns) }),
        ]

        return metrics.compactMap { (name, extractor) in
            let values = snapshots.map(extractor)
            guard let trend = TrendAnalysis.compute(metric: name, values: values) else {
                return nil
            }
            return ComplexityTrend(
                metricName: name,
                trend: trend,
                topDriftingModules: [],
                emergingPatterns: [],
                resolvedPatterns: []
            )
        }
    }

    /// Detects patterns that emerged or resolved between baseline and window reports.
    public func detectPatternChanges(
        baselineReports: [ComplexityReport],
        windowReports: [ComplexityReport]
    ) -> (emerging: [String], resolved: [String]) {
        let baselinePatterns = collectPatternNames(from: baselineReports)
        let windowPatterns = collectPatternNames(from: windowReports)

        let emerging = windowPatterns.subtracting(baselinePatterns).sorted()
        let resolved = baselinePatterns.subtracting(windowPatterns).sorted()

        return (emerging, resolved)
    }

    /// Builds full complexity trends enriched with drift and pattern changes.
    public func buildComplexityTrends(
        windowReports: [ComplexityReport],
        baselineReports: [ComplexityReport],
        scope: String
    ) -> [ComplexityTrend]? {
        let allReports = baselineReports + windowReports
        let snapshots = buildComplexitySnapshots(from: allReports, scope: scope)
        guard !snapshots.isEmpty else { return nil }

        var trends = analyzeComplexityTrends(from: snapshots)
        guard !trends.isEmpty else { return nil }

        let (emerging, resolved) = detectPatternChanges(
            baselineReports: baselineReports,
            windowReports: windowReports
        )

        let driftingModules = detectDriftingModules(
            baselineReports: baselineReports,
            windowReports: windowReports
        )

        for i in trends.indices {
            trends[i] = ComplexityTrend(
                metricName: trends[i].metricName,
                trend: trends[i].trend,
                topDriftingModules: driftingModules,
                emergingPatterns: emerging,
                resolvedPatterns: resolved
            )
        }

        return trends
    }

    /// Detects ViolationClusters from recurring complexity anti-patterns.
    ///
    /// Unlike the standard cluster detection (which scans failed diagnostics),
    /// this method scans ComplexityReport pattern breakdowns since complexity
    /// is advisory-only and never fails.
    public func detectComplexityClusters(
        from reports: [ComplexityReport],
        previousClusters: [ViolationCluster]
    ) -> [ViolationCluster] {
        var patternOccurrences: [String: Int] = [:]
        var patternProjects: [String: Set<String>] = [:]

        for report in reports {
            for (pattern, count) in report.summary.patternBreakdown {
                patternOccurrences[pattern, default: 0] += count
                patternProjects[pattern, default: []].insert(report.projectID)
            }
        }

        let previousByRule = Dictionary(
            uniqueKeysWithValues: previousClusters.map { ($0.ruleId, $0) }
        )

        return patternOccurrences
            .filter { $0.value >= 2 }
            .map { (pattern, count) in
                let ruleId = "complexity.\(pattern)"
                let prior = previousByRule[ruleId]
                let appearances = prior.map { ($0.consecutiveAppearances ?? 1) + 1 } ?? 1
                return ViolationCluster(
                    ruleId: ruleId,
                    occurrenceCount: count,
                    affectedProjectCount: patternProjects[pattern]?.count ?? 0,
                    dominantRootCause: nil,
                    dominantFailedStep: nil,
                    isRecurring: appearances >= PulseRefiner.minimumConsecutiveAppearances
                        && (patternProjects[pattern]?.count ?? 0) >= PulseRefiner.minimumAffectedProjectsForRecurring,
                    consecutiveAppearances: appearances
                )
            }
            .sorted { $0.occurrenceCount > $1.occurrenceCount }
    }

    /// Detects patterns that appear across multiple projects.
    ///
    /// Returns pattern names that occur in 2+ distinct projects, indicating
    /// a systemic gap in team knowledge rather than a project-specific issue.
    public func detectCrossProjectPatterns(
        projectReports: [String: [ComplexityReport]]
    ) -> [String] {
        var patternToProjects: [String: Set<String>] = [:]

        for (projectID, reports) in projectReports {
            for report in reports {
                for pattern in report.summary.patternBreakdown.keys {
                    patternToProjects[pattern, default: []].insert(projectID)
                }
            }
        }

        return patternToProjects
            .filter { $0.value.count >= 2 }
            .keys
            .sorted()
    }

    // MARK: - Private

    private func collectPatternNames(from reports: [ComplexityReport]) -> Set<String> {
        var names: Set<String> = []
        for report in reports {
            for key in report.summary.patternBreakdown.keys {
                names.insert(key)
            }
        }
        return names
    }

    private func detectDriftingModules(
        baselineReports: [ComplexityReport],
        windowReports: [ComplexityReport]
    ) -> [String] {
        var baselineMedians: [String: [Int]] = [:]
        for report in baselineReports {
            for module in report.modules {
                baselineMedians[module.moduleName, default: []].append(module.medianCognitive)
            }
        }

        var windowMedians: [String: [Int]] = [:]
        for report in windowReports {
            for module in report.modules {
                windowMedians[module.moduleName, default: []].append(module.medianCognitive)
            }
        }

        var drifts: [(String, Int)] = []
        for (moduleName, windowValues) in windowMedians {
            let windowAvg = windowValues.isEmpty ? 0 : windowValues.reduce(0, +) / windowValues.count
            let baselineValues = baselineMedians[moduleName] ?? []
            let baselineAvg = baselineValues.isEmpty ? 0 : baselineValues.reduce(0, +) / baselineValues.count
            let drift = windowAvg - baselineAvg
            if drift > 0 {
                drifts.append((moduleName, drift))
            }
        }

        return drifts
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map(\.0)
    }
}
