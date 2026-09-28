import Foundation

/// A rate as a whole percentage — or as nothing, when the rate is not a number.
///
/// Four views each carried their own `Int((value * 100).rounded())`, and each
/// would have stopped the dashboard on a NaN pass rate. The conversion lives here
/// once. What it returns for a rate it cannot convert is `nil`, not `0`: a
/// project whose pass rate is unknown has not failed everything.
enum WholePercent {

    /// What is shown in place of a percentage that does not exist.
    static let unknown = "—"

    /// The rate as a whole percentage.
    ///
    /// - Parameter rate: A rate, nominally in `0...1`.
    /// - Returns: The percentage, or nil when it cannot be represented.
    static func value(of rate: Double) -> Int? {
        Int(exactly: (rate * 100).rounded())
    }

    /// The rate as text: `88%`, or ``unknown``.
    ///
    /// - Parameter rate: A rate, nominally in `0...1`.
    /// - Returns: The percentage with its sign, or ``unknown``.
    static func text(of rate: Double) -> String {
        value(of: rate).map { "\($0)%" } ?? unknown
    }

    /// How many of `width` cells the rate fills.
    ///
    /// - Parameters:
    ///   - rate: A rate, nominally in `0...1`.
    ///   - width: The number of cells available.
    /// - Returns: A count in `0...width`, or nil when the rate is not a number.
    static func cells(of rate: Double, width: Int) -> Int? {
        guard width > 0 else { return 0 }
        guard let filled = Int(exactly: (rate * Double(width)).rounded()) else {
            // Not a number is unknown. Too large to convert is merely full.
            return rate.isNaN ? nil : (rate > 0 ? width : 0)
        }
        return min(max(filled, 0), width)
    }
}
