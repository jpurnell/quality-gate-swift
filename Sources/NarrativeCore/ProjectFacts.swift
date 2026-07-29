import Foundation

/// The trajectory facts for a single project, flattened for sharding.
public struct TrajectoryFacts: Sendable, Equatable {
    /// OLS trend direction: `improving`, `stable`, `declining`, or `insufficient`.
    public let direction: String
    /// Slope of the fitted line over daily weighted scores.
    public let slope: Double
    /// Coefficient of determination (fit quality, 0–1).
    public let rSquared: Double
    /// Number of data points the fit rests on.
    public let sampleSize: Int
    /// Whether a recent change in slope (an inflection) was detected.
    public let inflectionDetected: Bool
    /// The recent-window slope when an inflection is present, else `nil`.
    public let recentSlope: Double?

    /// Creates trajectory facts for one project.
    public init(
        direction: String,
        slope: Double,
        rSquared: Double,
        sampleSize: Int,
        inflectionDetected: Bool,
        recentSlope: Double?
    ) {
        self.direction = direction
        self.slope = slope
        self.rSquared = rSquared
        self.sampleSize = sampleSize
        self.inflectionDetected = inflectionDetected
        self.recentSlope = recentSlope
    }
}

/// A single anomaly scoped to one project, flattened for sharding.
public struct AnomalyFacts: Sendable, Equatable {
    /// The metric that deviated (e.g. `passRate`, `overrideRate`).
    public let metric: String
    /// Direction of the deviation: `positive` or `negative`.
    public let direction: String
    /// The observed value that triggered the anomaly.
    public let observedValue: Double
    /// The baseline-expected value.
    public let expectedValue: Double
    /// Standard deviations from baseline.
    public let zScore: Double
    /// Statistical-maturity gate on the severity (e.g. `confirmed`, `directional`).
    public let gatedSeverity: String
    /// Recommended action (e.g. `investigate`, `monitor`).
    public let actionability: String

    /// Creates anomaly facts for one project.
    public init(
        metric: String,
        direction: String,
        observedValue: Double,
        expectedValue: Double,
        zScore: Double,
        gatedSeverity: String,
        actionability: String
    ) {
        self.metric = metric
        self.direction = direction
        self.observedValue = observedValue
        self.expectedValue = expectedValue
        self.zScore = zScore
        self.gatedSeverity = gatedSeverity
        self.actionability = actionability
    }
}

/// A single work-log entry for one project, flattened for sharding.
public struct WorkFacts: Sendable, Equatable {
    /// The run day this work was captured on.
    public let date: Date
    /// The commit SHA the gate ran against, if any.
    public let commitSHA: String?
    /// Subjects of the commits new in this entry.
    public let commitSubjects: [String]

    /// Creates work facts for one project.
    public init(date: Date, commitSHA: String?, commitSubjects: [String]) {
        self.date = date
        self.commitSHA = commitSHA
        self.commitSubjects = commitSubjects
    }
}

/// Everything the narrator needs about ONE project, already isolated from every
/// other project. This is the per-project substrate the map step turns into a
/// narrative — deriving it (via the pulse extractor) is where cross-project
/// contamination is prevented; formatting it (via ``ProjectSharder``) is pure.
public struct ProjectFacts: Sendable, Equatable {
    /// The project identifier.
    public let projectID: String
    /// Whether the project passed all checkers at snapshot time.
    public let passing: Bool
    /// The checkers that failed, when not passing.
    public let failedCheckers: [String]
    /// Count of active overrides on the project.
    public let overrideCount: Int
    /// The project's weighted quality score (0–1), if scored.
    public let weightedScore: Double?
    /// The project's tier (e.g. `active`, `baseline`), if assigned.
    public let tier: String?
    /// The project's trajectory, if computable.
    public let trajectory: TrajectoryFacts?
    /// This project's anomalies only (scope == projectID).
    public let anomalies: [AnomalyFacts]
    /// This project's work-log entries only, any order (the sharder sorts + caps).
    public let work: [WorkFacts]

    /// Creates isolated facts for one project.
    public init(
        projectID: String,
        passing: Bool,
        failedCheckers: [String] = [],
        overrideCount: Int = 0,
        weightedScore: Double? = nil,
        tier: String? = nil,
        trajectory: TrajectoryFacts? = nil,
        anomalies: [AnomalyFacts] = [],
        work: [WorkFacts] = []
    ) {
        self.projectID = projectID
        self.passing = passing
        self.failedCheckers = failedCheckers
        self.overrideCount = overrideCount
        self.weightedScore = weightedScore
        self.tier = tier
        self.trajectory = trajectory
        self.anomalies = anomalies
        self.work = work
    }
}
