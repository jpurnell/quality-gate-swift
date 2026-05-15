import Foundation

/// Classifies the reliability of a statistical result based on sample size.
///
/// The Central Limit Theorem requires approximately 30 observations for
/// the sampling distribution of the mean to be approximately normal.
/// Results below this threshold are computed but explicitly marked as
/// preliminary — consumers should weight them accordingly.
public enum StatisticalValidity: String, Sendable, Codable, Comparable {
    /// Fewer than 3 data points. No meaningful statistics possible.
    case insufficient
    /// 3-29 data points. Results are computed but not statistically valid.
    case preliminary
    /// 30+ data points. Results meet the Central Limit Theorem threshold.
    case valid

    /// Compares validity levels by reliability.
    public static func < (lhs: StatisticalValidity, rhs: StatisticalValidity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    /// Determines validity from a sample size.
    public static func from(sampleSize: Int) -> StatisticalValidity {
        if sampleSize < 3 { return .insufficient }
        if sampleSize < 30 { return .preliminary }
        return .valid
    }

    private var sortOrder: Int {
        switch self {
        case .insufficient: 0
        case .preliminary: 1
        case .valid: 2
        }
    }
}
