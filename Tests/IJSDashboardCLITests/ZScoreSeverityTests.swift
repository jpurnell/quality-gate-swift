import Testing
import Foundation
@testable import IJSDashboardCLI
import SwiftCLIKit

@Suite("ZScoreSeverity — an anomaly score that is not a number is not a mild one")
struct ZScoreSeverityTests {

    @Test("Magnitudes fall either side of the 95% and 99% thresholds")
    func sortsByThreshold() {
        #expect(ZScoreSeverity(magnitude: 3.0) == .severe)
        #expect(ZScoreSeverity(magnitude: 2.576) == .elevated)
        #expect(ZScoreSeverity(magnitude: 2.0) == .elevated)
        #expect(ZScoreSeverity(magnitude: 1.96) == .elevated)
        #expect(ZScoreSeverity(magnitude: 1.0) == .mild)
        #expect(ZScoreSeverity(magnitude: 0.0) == .mild)
    }

    @Test("A NaN is unknown, where it used to be mild")
    func refusesNaN() {
        #expect(ZScoreSeverity(magnitude: .nan) == .unknown)
    }

    @Test("An infinite score is as severe as a score gets")
    func infinityIsSevere() {
        #expect(ZScoreSeverity(magnitude: .infinity) == .severe)
    }

    @Test("Each severity has its own colour, and unknown has none of the three")
    func colours() {
        #expect(ZScoreSeverity.severe.colour == ANSICodes.fg(.red))
        #expect(ZScoreSeverity.elevated.colour == ANSICodes.fg(.yellow))
        #expect(ZScoreSeverity.mild.colour == ANSICodes.fg(.cyan))
        #expect(ZScoreSeverity.unknown.colour == ANSICodes.dim)
    }
}
