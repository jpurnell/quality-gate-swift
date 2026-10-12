import Foundation

/// Whether a definition the index reports is still written where the index says it is.
///
/// An index occurrence is a record of a past compilation: a name, a file, a line. Nothing in
/// it says the file still reads that way. A checker that anchors a finding to that line is
/// quoting the index to a reader who will open the file, so before the quotation is made it
/// should at least survive being read against the source.
///
/// This is the *minimum* check and deliberately no more than that. It asks whether the line
/// still mentions the symbol's name as a whole identifier; it does not ask whether the line
/// still declares the same *kind* of thing, or the same symbol among overloads. A stale
/// occurrence whose line happens to mention the same name passes. What it rules out is the
/// case that is indistinguishable from a correct finding until the file is opened: a named
/// symbol reported at a line that holds a different declaration.
///
/// The predicate lives here, beside the index infrastructure, because every index-backed
/// checker that anchors a finding to an indexed definition needs the same answer. *Applying*
/// it stays with each consumer: only the consumer knows which occurrence it is about to turn
/// into a finding, and what it should do — and say — when the source disagrees.
public enum IndexedDeclaration {

    /// The identifier a symbol is declared with, taken from the name the index stores.
    ///
    /// The index names a function with its argument labels — `validate(_:)`, `init(from:)` —
    /// and a property or enum case by its bare name. The source line carries only the part
    /// before the parenthesis.
    ///
    /// - Parameter name: The symbol's name as IndexStoreDB reports it.
    /// - Returns: The name up to its first `(`, or the whole name when that would be empty —
    ///   the call operator is indexed as `(_:)` and has no shorter spelling.
    public static func baseName(ofIndexedName name: String) -> String {
        guard let parenthesis = name.firstIndex(of: "(") else { return name }
        let base = name[name.startIndex..<parenthesis]
        return base.isEmpty ? name : String(base)
    }

    /// Whether `line` still mentions the symbol the index recorded on it.
    ///
    /// - Parameters:
    ///   - indexedName: The symbol's name as IndexStoreDB reports it.
    ///   - line: The text of the recorded line in the *current* source, or `nil` when the file
    ///     no longer has that many lines.
    /// - Returns: `true` when the symbol's base name occurs on the line as a whole identifier.
    ///   A name with no usable base — the call operator — cannot be checked this way and is
    ///   reported as present: an unverifiable occurrence is not evidence of a stale one.
    public static func appears(indexedName: String, inSourceLine line: String?) -> Bool {
        guard let text = line else { return false }
        let base = baseName(ofIndexedName: indexedName)
        guard !base.contains("(") else { return true }
        guard let first = base.unicodeScalars.first, let last = base.unicodeScalars.last else {
            return true
        }
        // An operator is not bounded by identifier characters, so `+` beside `a` is a match;
        // an identifier is, so `last` inside `lastQRCodeError` is not.
        let boundedAtStart = isIdentifierScalar(first)
        let boundedAtEnd = isIdentifierScalar(last)

        var searchStart = text.startIndex
        while let found = text.range(of: base, range: searchStart..<text.endIndex) {
            let precededByIdentifier = found.lowerBound > text.startIndex
                && text[text.index(before: found.lowerBound)].unicodeScalars.allSatisfy(isIdentifierScalar)
            let followedByIdentifier = found.upperBound < text.endIndex
                && text[found.upperBound].unicodeScalars.allSatisfy(isIdentifierScalar)
            if !(boundedAtStart && precededByIdentifier) && !(boundedAtEnd && followedByIdentifier) {
                return true
            }
            searchStart = text.index(after: found.lowerBound)
        }
        return false
    }

    /// Whether a scalar can continue a Swift identifier, closely enough for a boundary test.
    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
