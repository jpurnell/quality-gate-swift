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

    /// The stream with every record removed.
    public static func stripping(_ stderr: String) -> String {
        let kept = stderr.lines.filter { !$0.hasPrefix(sentinel) }
        guard !kept.isEmpty else { return "" }
        return kept.joined(separator: "\n") + (stderr.hasSuffix("\n") ? "\n" : "")
    }
}
