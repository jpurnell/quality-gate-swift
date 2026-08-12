import Foundation
import QualityGateCore

/// How a region's body differs from what its generator produced.
///
/// The comparison is byte-exact. A "close enough" comparator — one that trims each line, or
/// folds runs of spaces — is the first thing a reimplementation reaches for and the first
/// thing that makes the check meaningless, because the whole claim is that the region *is*
/// the generator's output.
public struct RegionDiff: Sendable, Equatable {

    /// A line the document contains that the generator did not produce, and where it sits.
    public struct ExtraLine: Sendable, Equatable {
        /// The line's text.
        public let text: String
        /// Its 1-based line number in the governed file.
        public let line: Int

        /// Creates an extra line.
        public init(text: String, line: Int) {
            self.text = text
            self.line = line
        }
    }

    /// Lines the generator produced that the region does not contain.
    public let missing: [String]

    /// Lines the region contains that the generator did not produce.
    public let unexpected: [ExtraLine]

    /// Whether the bodies are byte-identical.
    public let matches: Bool

    /// Compares a region body against a generated body.
    ///
    /// - Parameters:
    ///   - current: The bytes currently between the delimiters.
    ///   - generated: What the generator produced.
    ///   - bodyStartLine: The governed file's line number of the body's first line, so an
    ///     unexpected line can be reported where a reader will find it.
    public init(current: String, generated: String, bodyStartLine: Int) {
        matches = current == generated
        let currentLines = current.isEmpty ? [] : current.lines
        let generatedLines = generated.isEmpty ? [] : generated.lines
        comparedCurrentLines = currentLines
        comparedGeneratedLines = generatedLines

        var currentCounts: [String: Int] = [:]
        for line in currentLines { currentCounts[line, default: 0] += 1 }
        var generatedCounts: [String: Int] = [:]
        for line in generatedLines { generatedCounts[line, default: 0] += 1 }

        missing = generatedLines.filter { (generatedCounts[$0] ?? 0) > (currentCounts[$0] ?? 0) }
        unexpected = currentLines.enumerated()
            .filter { (currentCounts[$0.element] ?? 0) > (generatedCounts[$0.element] ?? 0) }
            .map { ExtraLine(text: $0.element, line: bodyStartLine + $0.offset) }
    }

    /// Whether the bodies differ in whitespace alone.
    ///
    /// Worth its own answer, and worth being an error rather than a shrug. A reader shown
    /// `+ | row |` beside `- | row |` — two lines that differ by a trailing space and look
    /// identical on screen — concludes the checker is broken. Saying "whitespace only" says
    /// the true thing, and keeping it red says the other true thing: the claim is that the
    /// region *is* the generator's output, and a trailing space means it is not.
    public var differsOnlyInWhitespace: Bool {
        guard !matches else { return false }
        let trim = { (line: String) in line.trimmingCharacters(in: .whitespaces) }
        return comparedCurrentLines.map(trim) == comparedGeneratedLines.map(trim)
    }

    /// The compared bodies' lines, retained so ``differsOnlyInWhitespace`` can answer without
    /// splitting them a second time.
    private let comparedCurrentLines: [String]
    private let comparedGeneratedLines: [String]
}
