import Foundation

/// Direction of a project's quality trend over time.
public enum TrajectoryDirection: String, Sendable, Codable {
    /// Quality score is trending upward.
    case improving
    /// Quality score is essentially flat.
    case stable
    /// Quality score is trending downward.
    case declining
    /// Too few data points to determine direction.
    case insufficient

    /// Derives direction from a linear regression slope and sample size.
    public static func from(slope: Double, sampleSize: Int) -> TrajectoryDirection {
        if sampleSize < 3 { return .insufficient }
        if abs(slope) < 0.005 { return .stable }
        return slope > 0 ? .improving : .declining
    }
}

/// Linear regression trajectory for a project's weighted quality score.
public struct ProjectTrajectory: Sendable, Codable, Equatable {
    /// Identifier of the project this trajectory describes.
    public let projectID: String
    /// Regression slope (positive = improving).
    public let slope: Double
    /// Regression y-intercept.
    public let intercept: Double
    /// Coefficient of determination for the fit.
    public let rSquared: Double
    /// Number of data points used in the regression.
    public let sampleSize: Int
    /// Statistical validity classification of this trajectory.
    public let validity: StatisticalValidity
    /// Derived direction from slope and sample size.
    public let direction: TrajectoryDirection
    /// Whether a recent inflection (trend reversal) was detected.
    public let inflectionDetected: Bool
    /// Slope computed from recent data only, if an inflection was detected.
    public let recentSlope: Double?

    /// Creates a project trajectory from regression results.
    public init(
        projectID: String,
        slope: Double,
        intercept: Double,
        rSquared: Double,
        sampleSize: Int,
        validity: StatisticalValidity,
        direction: TrajectoryDirection,
        inflectionDetected: Bool = false,
        recentSlope: Double? = nil
    ) {
        self.projectID = projectID
        self.slope = slope
        self.intercept = intercept
        self.rSquared = rSquared
        self.sampleSize = sampleSize
        self.validity = validity
        self.direction = direction
        self.inflectionDetected = inflectionDetected
        self.recentSlope = recentSlope
    }
}
