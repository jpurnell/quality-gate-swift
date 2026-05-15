import Foundation

/// How a consistency finding was matched against institutional history.
public enum ConsistencyMatchType: String, Sendable, Codable {
    /// Matches a ViolationCluster from the most recent Pulse.
    case clusterMatch
    /// Matches a pattern that triggered a negative StatisticalAnomaly.
    case anomalyPattern
    /// Matches a calibration's proposed policy update that was not yet implemented.
    case unaddressedPolicy
}
