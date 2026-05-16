import Foundation
import IJSSensor

/// Converts per-function complexity records into a corpus-ready ComplexityReport.
public struct ComplexityTelemetryEmitter {

    /// Builds a ComplexityReport from analyzed function records.
    public static func buildReport(
        from records: [FunctionComplexityRecord],
        projectID: String,
        timestamp: Date,
        threshold: Int
    ) -> ComplexityReport {
        guard !records.isEmpty else {
            return ComplexityReport(
                projectID: projectID,
                timestamp: timestamp,
                modules: [],
                summary: ComplexitySummary(
                    totalFunctions: 0,
                    medianCognitive: 0,
                    p90Cognitive: 0,
                    maxCognitive: 0,
                    complexityDistribution: [:],
                    totalPatterns: 0,
                    patternBreakdown: [:]
                )
            )
        }

        let grouped = Dictionary(grouping: records, by: \.moduleName)
        let modules = grouped.map { moduleName, moduleRecords in
            buildModuleReport(moduleName: moduleName, records: moduleRecords, threshold: threshold)
        }.sorted { $0.moduleName < $1.moduleName }

        let allCognitive = records.map(\.cognitiveComplexity).sorted()
        let medianCognitive = median(allCognitive)
        let p90Cognitive = percentile(allCognitive, p: 90)
        let maxCognitive = allCognitive.last ?? 0

        var distribution: [String: Int] = [:]
        for record in records {
            distribution[record.estimatedTimeComplexity, default: 0] += 1
        }

        var patternBreakdown: [String: Int] = [:]
        var totalPatterns = 0
        for record in records {
            for pattern in record.detectedPatterns {
                let key = patternKey(pattern)
                patternBreakdown[key, default: 0] += 1
                totalPatterns += 1
            }
        }

        let functionsAboveThreshold = records.filter { $0.cognitiveComplexity > threshold }.count

        let summary = ComplexitySummary(
            totalFunctions: records.count,
            medianCognitive: medianCognitive,
            p90Cognitive: p90Cognitive,
            maxCognitive: maxCognitive,
            complexityDistribution: distribution,
            totalPatterns: totalPatterns,
            patternBreakdown: patternBreakdown,
            functionsAboveThreshold: functionsAboveThreshold
        )

        return ComplexityReport(
            projectID: projectID,
            timestamp: timestamp,
            modules: modules,
            summary: summary
        )
    }

    /// Builds a ComplexitySnapshot from a report for corpus storage.
    public static func buildSnapshot(
        from report: ComplexityReport,
        date: String,
        scope: String
    ) -> ComplexitySnapshot {
        ComplexitySnapshot(
            date: date,
            scope: scope,
            medianCognitive: report.summary.medianCognitive,
            p90Cognitive: report.summary.p90Cognitive,
            maxCognitive: report.summary.maxCognitive,
            totalPatterns: report.summary.totalPatterns,
            functionsAboveThreshold: report.summary.functionsAboveThreshold,
            dominantBigO: dominantBigO(from: report.summary.complexityDistribution)
        )
    }

    // MARK: - Private

    private static func buildModuleReport(
        moduleName: String,
        records: [FunctionComplexityRecord],
        threshold: Int
    ) -> ModuleComplexityReport {
        let cognitive = records.map(\.cognitiveComplexity).sorted()
        var patternCounts: [String: Int] = [:]
        for record in records {
            for pattern in record.detectedPatterns {
                patternCounts[patternKey(pattern), default: 0] += 1
            }
        }

        var bigOCounts: [String: Int] = [:]
        for record in records {
            bigOCounts[record.estimatedTimeComplexity, default: 0] += 1
        }

        return ModuleComplexityReport(
            moduleName: moduleName,
            functionCount: records.count,
            medianCognitive: median(cognitive),
            maxCognitive: cognitive.last ?? 0,
            functionsAboveThreshold: records.filter { $0.cognitiveComplexity > threshold }.count,
            dominantBigO: dominantBigO(from: bigOCounts),
            patternCounts: patternCounts
        )
    }

    private static func median(_ sorted: [Int]) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func percentile(_ sorted: [Int], p: Int) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = (p * sorted.count) / 100
        return sorted[min(index, sorted.count - 1)]
    }

    private static func dominantBigO(from distribution: [String: Int]) -> String {
        distribution.max { $0.value < $1.value }?.key ?? "O(1)"
    }

    private static func patternKey(_ pattern: ComplexityPattern) -> String {
        switch pattern {
        case .containsInFilter: return "containsInFilter"
        case .nestedLoopSameCollection: return "nestedLoopSameCollection"
        case .repeatedLinearSearch: return "repeatedLinearSearch"
        case .sortInLoop: return "sortInLoop"
        case .quadraticStringConcat: return "quadraticStringConcat"
        }
    }
}
