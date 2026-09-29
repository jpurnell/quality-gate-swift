import Foundation
import SwiftCLIKit

/// How far from ordinary an anomaly's z-score is.
///
/// Two views sorted the score with `if z > 2.576 … else if z >= 1.96 … else`,
/// and a NaN passes neither comparison, so an anomaly whose score could not be
/// computed was drawn in the colour of the mildest kind.
enum ZScoreSeverity: Equatable {
    /// Beyond the 99% threshold.
    case severe
    /// Beyond the 95% threshold.
    case elevated
    /// Within it.
    case mild
    /// The score is not a number.
    case unknown

    /// Sorts the magnitude of a z-score.
    /// - Parameter magnitude: The absolute value of the score.
    init(magnitude: Double) {
        if magnitude.isNaN {
            self = .unknown
        } else if magnitude > 2.576 {
            self = .severe
        } else if magnitude >= 1.96 {
            self = .elevated
        } else {
            self = .mild
        }
    }

    /// The colour the severity is drawn in.
    var colour: String {
        switch self {
        case .severe: ANSICodes.fg(.red)
        case .elevated: ANSICodes.fg(.yellow)
        case .mild: ANSICodes.fg(.cyan)
        case .unknown: ANSICodes.dim
        }
    }
}
