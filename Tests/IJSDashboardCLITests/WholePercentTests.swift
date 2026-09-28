import Testing
import Foundation
@testable import IJSDashboardCLI

@Suite("WholePercent — a rate that is not a number is not a percentage")
struct WholePercentTests {

    @Test("An ordinary rate rounds to the nearest whole percent")
    func roundsOrdinaryRate() {
        #expect(WholePercent.value(of: 0.876) == 88)
        #expect(WholePercent.value(of: 0.0) == 0)
        #expect(WholePercent.value(of: 1.0) == 100)
        #expect(WholePercent.text(of: 0.876) == "88%")
    }

    @Test("A NaN rate has no value, and is shown as unknown rather than as a number")
    func refusesNaN() {
        #expect(WholePercent.value(of: .nan) == nil)
        #expect(WholePercent.text(of: .nan) == "—")
    }

    @Test("An infinite or unrepresentable rate has no value")
    func refusesUnrepresentable() {
        #expect(WholePercent.value(of: .infinity) == nil)
        #expect(WholePercent.value(of: -.infinity) == nil)
        #expect(WholePercent.value(of: 1e300) == nil)
        #expect(WholePercent.text(of: 1e300) == "—")
    }

    @Test("A gauge fills in proportion to the rate")
    func fillsGauge() {
        #expect(WholePercent.cells(of: 0.5, width: 20) == 10)
        #expect(WholePercent.cells(of: 0.0, width: 20) == 0)
        #expect(WholePercent.cells(of: 1.0, width: 20) == 20)
    }

    @Test("A gauge never overflows its width, and an unknown rate fills nothing")
    func boundsGauge() {
        #expect(WholePercent.cells(of: 1.5, width: 20) == 20)
        #expect(WholePercent.cells(of: -0.5, width: 20) == 0)
        #expect(WholePercent.cells(of: .nan, width: 20) == nil)
        #expect(WholePercent.cells(of: 0.5, width: 0) == 0)
    }
}
