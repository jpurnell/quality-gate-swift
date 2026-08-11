import Foundation
import QualityGateCore

/// One measured value, reported by an assertion injected into the running article.
///
/// The channel is stderr, prefixed with a sentinel no documentation example would print.
/// stdout could not be used: `Output:` claims are verified by *consuming* stdout in order,
/// and instrumentation written into that stream would shift every line a claim binds to.
///
/// The records are stripped from the stderr the verdict reports, because they are the
/// checker's own instrumentation — showing them as though the article printed them would be
/// a statement about the documentation that is not true.
public struct ClaimRecord: Sendable, Equatable {

    /// What kind of value the assertion could see.
    public enum Shape: String, Sendable, Equatable {

        /// A single number.
        case scalar

        /// A sequence of numbers.
        case sequence

        /// A value that is neither, so no numeric comparison is possible.
        ///
        /// Reported rather than dropped. A `TimeSeries` binding cannot be compared against a
        /// documented figure — its values are private, and the assembler has no business
        /// knowing the public accessor — and the gap between claims *found* and claims
        /// *checked* has to be visible or the coverage number is a fiction.
        case opaque
    }

    /// The article line of the claim this record answers.
    public let articleLine: Int

    /// What the value turned out to be.
    public let shape: Shape

    /// The measured numbers, empty for ``Shape/opaque``.
    public let values: [Double]

    /// The Swift type name, for reporting an opaque value usefully.
    public let typeName: String

    /// Creates a record.
    public init(articleLine: Int, shape: Shape, values: [Double], typeName: String) {
        self.articleLine = articleLine
        self.shape = shape
        self.values = values
        self.typeName = typeName
    }

    /// The sentinel that opens every record.
    ///
    /// A control character rather than a word, so no article that happens to write about
    /// this checker can forge one.
    static let sentinel = "\u{1}QGCLAIM\u{1}"

    /// Parses every record out of a captured stderr stream.
    ///
    /// - Parameter stderr: The stream as the process wrote it.
    /// - Returns: The records, in the order the program emitted them.
    public static func parse(_ stderr: String) -> [ClaimRecord] {
        stderr.lines.compactMap { line in
            guard line.hasPrefix(sentinel) else { return nil }
            let fields = line.dropFirst(sentinel.count).components(separatedBy: "\u{1}")
            guard fields.count >= 4,
                  let articleLine = Int(fields[0]),
                  let shape = Shape(rawValue: fields[1]) else { return nil }
            let values = fields[3].isEmpty
                ? []
                : fields[3].components(separatedBy: ",").compactMap(Double.init)
            return ClaimRecord(
                articleLine: articleLine, shape: shape, values: values, typeName: fields[2])
        }
    }

    /// How many claim values differ between two runs of the same program.
    ///
    /// Compared with ``ClaimComparison/identical(_:_:)`` rather than `==`, because this is a
    /// reproducibility claim and nothing else: `==` would silently pass a value that had gone
    /// NaN on both runs, and would call `-0.0` and `0.0` the same stream.
    ///
    /// - Parameters:
    ///   - first: Records from the first run.
    ///   - second: Records from the second.
    /// - Returns: The number of claims whose measured value was not reproduced. A claim that
    ///   appeared in one run and not the other counts as differing.
    public static func differences(_ first: [ClaimRecord], _ second: [ClaimRecord]) -> Int {
        let later = Dictionary(second.map { ($0.articleLine, $0) }, uniquingKeysWith: { a, _ in a })
        var differing = 0
        for record in first {
            guard let other = later[record.articleLine],
                  other.values.count == record.values.count,
                  zip(record.values, other.values).allSatisfy(ClaimComparison.identical)
            else {
                differing += 1
                continue
            }
        }
        return differing + max(0, later.count - first.count)
    }

    /// The stream with every record removed.
    public static func stripping(_ stderr: String) -> String {
        let kept = stderr.lines.filter { !$0.hasPrefix(sentinel) }
        guard !kept.isEmpty else { return "" }
        return kept.joined(separator: "\n") + (stderr.hasSuffix("\n") ? "\n" : "")
    }
}
