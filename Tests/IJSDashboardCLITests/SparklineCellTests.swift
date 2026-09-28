import Testing
import Foundation
@testable import IJSDashboardCLI

@Suite("SparklineCell — a value that is not a number has no height")
struct SparklineCellTests {

    @Test("Values map across the available cells")
    func mapsAcrossCells() {
        #expect(SparklineCell.index(of: 0.0, minimum: 0.0, range: 1.0, cells: 8) == 0)
        #expect(SparklineCell.index(of: 0.5, minimum: 0.0, range: 1.0, cells: 8) == 3)
        #expect(SparklineCell.index(of: 1.0, minimum: 0.0, range: 1.0, cells: 8) == 7)
    }

    @Test("A value outside the range is held at the nearest cell")
    func holdsAtNearestCell() {
        #expect(SparklineCell.index(of: 2.0, minimum: 0.0, range: 1.0, cells: 8) == 7)
        #expect(SparklineCell.index(of: -1.0, minimum: 0.0, range: 1.0, cells: 8) == 0)
    }

    @Test("A NaN has no cell")
    func refusesNaN() {
        #expect(SparklineCell.index(of: .nan, minimum: 0.0, range: 1.0, cells: 8) == nil)
        #expect(SparklineCell.index(of: 0.5, minimum: .nan, range: 1.0, cells: 8) == nil)
        #expect(SparklineCell.index(of: 0.5, minimum: 0.0, range: .nan, cells: 8) == nil)
    }

    @Test("A range of zero, or no cells, has no cell")
    func refusesDegenerateInput() {
        #expect(SparklineCell.index(of: 0.5, minimum: 0.0, range: 0.0, cells: 8) == nil)
        #expect(SparklineCell.index(of: 0.5, minimum: 0.0, range: 1.0, cells: 0) == nil)
    }
}
