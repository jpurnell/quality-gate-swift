import Foundation

/// Which cell of a sparkline a value falls in.
enum SparklineCell {

    /// The cell for `value`, or nil when it has none.
    ///
    /// - Parameters:
    ///   - value: The value to place.
    ///   - minimum: The smallest value in the series.
    ///   - range: The spread of the series.
    ///   - cells: How many cells there are.
    /// - Returns: An index in `0..<cells`, or nil when any input is not a number,
    ///   the range is zero, or there are no cells.
    static func index(of value: Double, minimum: Double, range: Double, cells: Int) -> Int? {
        // A NaN range fails this guard too: no comparison with one is true.
        guard cells > 0, range > 0 else { return nil }

        let scaled = ((value - minimum) / range * Double(cells - 1)).rounded(.towardZero)
        guard !scaled.isNaN else { return nil }
        guard let cell = Int(exactly: scaled) else {
            // Too large to convert is not unknown. It is off the end.
            return scaled > 0 ? cells - 1 : 0
        }
        return min(max(cell, 0), cells - 1)
    }
}
