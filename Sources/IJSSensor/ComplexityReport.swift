import Foundation

/// Per-run complexity report emitted to the IJS corpus alongside CheckResultMetadata.
///
/// Stores aggregate complexity metrics for trend analysis by the PulseRefiner.
/// File convention: `telemetry/<projectID>/YYYY-MM-DD/HHmmss_complexity.json`
public struct ComplexityReport: Sendable, Codable, Equatable {
    /// Project identifier matching the corpus hierarchy.
    public let projectID: String
    /// Timestamp of the gate run that produced this report.
    public let timestamp: Date
    /// Per-module complexity breakdowns.
    public let modules: [ModuleComplexityReport]
    /// Aggregate summary across all modules.
    public let summary: ComplexitySummary

    /// Creates a complexity report.
    public init(
        projectID: String,
        timestamp: Date,
        modules: [ModuleComplexityReport],
        summary: ComplexitySummary
    ) {
        self.projectID = projectID
        self.timestamp = timestamp
        self.modules = modules
        self.summary = summary
    }
}

/// Per-module complexity breakdown within a ComplexityReport.
public struct ModuleComplexityReport: Sendable, Codable, Equatable {
    /// Module name from SPM target.
    public let moduleName: String
    /// Total number of functions analyzed.
    public let functionCount: Int
    /// Median cognitive complexity across functions.
    public let medianCognitive: Int
    /// Maximum cognitive complexity in this module.
    public let maxCognitive: Int
    /// Functions exceeding the configured threshold.
    public let functionsAboveThreshold: Int
    /// Most common Big-O class in this module.
    public let dominantBigO: String
    /// Anti-pattern type to count mapping.
    public let patternCounts: [String: Int]

    /// Creates a module complexity report.
    public init(
        moduleName: String,
        functionCount: Int,
        medianCognitive: Int,
        maxCognitive: Int,
        functionsAboveThreshold: Int,
        dominantBigO: String,
        patternCounts: [String: Int]
    ) {
        self.moduleName = moduleName
        self.functionCount = functionCount
        self.medianCognitive = medianCognitive
        self.maxCognitive = maxCognitive
        self.functionsAboveThreshold = functionsAboveThreshold
        self.dominantBigO = dominantBigO
        self.patternCounts = patternCounts
    }
}

/// Aggregate complexity summary across all modules in a single gate run.
public struct ComplexitySummary: Sendable, Codable, Equatable {
    /// Total functions analyzed.
    public let totalFunctions: Int
    /// Median cognitive complexity across all functions.
    public let medianCognitive: Int
    /// 90th percentile cognitive complexity.
    public let p90Cognitive: Int
    /// Maximum cognitive complexity across all functions.
    public let maxCognitive: Int
    /// Big-O class to function count (e.g., "O(1)": 45, "O(n)": 30).
    public let complexityDistribution: [String: Int]
    /// Total anti-patterns detected across all functions.
    public let totalPatterns: Int
    /// Anti-pattern type to count mapping.
    public let patternBreakdown: [String: Int]
    /// Functions exceeding the configured threshold.
    public let functionsAboveThreshold: Int

    /// Creates a complexity summary.
    public init(
        totalFunctions: Int,
        medianCognitive: Int,
        p90Cognitive: Int,
        maxCognitive: Int,
        complexityDistribution: [String: Int],
        totalPatterns: Int,
        patternBreakdown: [String: Int],
        functionsAboveThreshold: Int = 0
    ) {
        self.totalFunctions = totalFunctions
        self.medianCognitive = medianCognitive
        self.p90Cognitive = p90Cognitive
        self.maxCognitive = maxCognitive
        self.complexityDistribution = complexityDistribution
        self.totalPatterns = totalPatterns
        self.patternBreakdown = patternBreakdown
        self.functionsAboveThreshold = functionsAboveThreshold
    }
}

/// Daily complexity snapshot for trend analysis (parallel to DailySnapshot).
///
/// Stored at: `<basePath>/snapshots/complexity-<scope>/YYYY-MM-DD.json`
public struct ComplexitySnapshot: Sendable, Codable, Equatable {
    /// Date string in YYYY-MM-DD format.
    public let date: String
    /// Scope identifier (project ID or "corpus").
    public let scope: String
    /// Median cognitive complexity for this day.
    public let medianCognitive: Int
    /// 90th percentile cognitive complexity.
    public let p90Cognitive: Int
    /// Maximum cognitive complexity.
    public let maxCognitive: Int
    /// Total anti-patterns detected.
    public let totalPatterns: Int
    /// Functions exceeding threshold.
    public let functionsAboveThreshold: Int
    /// Most common Big-O class.
    public let dominantBigO: String

    /// Creates a complexity snapshot.
    public init(
        date: String,
        scope: String,
        medianCognitive: Int,
        p90Cognitive: Int,
        maxCognitive: Int,
        totalPatterns: Int,
        functionsAboveThreshold: Int,
        dominantBigO: String
    ) {
        self.date = date
        self.scope = scope
        self.medianCognitive = medianCognitive
        self.p90Cognitive = p90Cognitive
        self.maxCognitive = maxCognitive
        self.totalPatterns = totalPatterns
        self.functionsAboveThreshold = functionsAboveThreshold
        self.dominantBigO = dominantBigO
    }
}

/// Complexity trend analysis enriched with drift and pattern emergence info.
///
/// Wraps the existing `TrendAnalysis` model with complexity-specific metadata.
public struct ComplexityTrend: Sendable, Codable, Equatable {
    /// The metric being tracked (e.g., "medianCognitive", "p90Cognitive", "patternCount").
    public let metricName: String
    /// Statistical trend for this metric.
    public let trend: TrendAnalysis
    /// Modules whose complexity increased most over the window.
    public let topDriftingModules: [String]
    /// Anti-patterns appearing for the first time in this window.
    public let emergingPatterns: [String]
    /// Anti-patterns that disappeared in this window.
    public let resolvedPatterns: [String]

    /// Creates a complexity trend.
    public init(
        metricName: String,
        trend: TrendAnalysis,
        topDriftingModules: [String],
        emergingPatterns: [String],
        resolvedPatterns: [String]
    ) {
        self.metricName = metricName
        self.trend = trend
        self.topDriftingModules = topDriftingModules
        self.emergingPatterns = emergingPatterns
        self.resolvedPatterns = resolvedPatterns
    }
}
