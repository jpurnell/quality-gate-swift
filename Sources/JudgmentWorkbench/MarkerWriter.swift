import Foundation

/// Typed failures from ``MarkerWriter``.
public enum MarkerWriterError: Error, Sendable, Equatable {
    /// The requested 1-based line does not exist in the source.
    case lineOutOfRange(line: Int, lineCount: Int)
}

/// Pure text surgery: writes an acknowledgment marker at a flagged location.
///
/// The writer preserves everything it does not touch — surrounding lines
/// byte-for-byte, CRLF line endings, and the presence or absence of a
/// trailing newline — and is idempotent: a line (or, for
/// ``MarkerPlacement/lineAbove``, its predecessor) that already carries the
/// marker is left unchanged.
public enum MarkerWriter {

    /// Writes `marker` (plus an optional reason continuation) at the given
    /// 1-based line of `source` and returns the updated text.
    ///
    /// For ``MarkerPlacement/endOfLine`` the marker is appended to the flagged
    /// line with exactly one space before the `//` (trailing whitespace on the
    /// line is trimmed to guarantee that). For ``MarkerPlacement/lineAbove``
    /// the marker becomes its own comment line above the flagged line,
    /// matching its indentation — the placement leading-trivia detectors
    /// require.
    ///
    /// - Parameters:
    ///   - marker: The comment marker, including the leading `//`.
    ///   - reason: Optional human rationale; newlines are collapsed to spaces
    ///     and the text is appended after the marker. Trailing text is safe
    ///     for every registered end-of-line marker because their auditors
    ///     detect via substring `contains()`.
    ///   - placement: Where to write the marker. Defaults to end-of-line.
    ///   - line: The 1-based flagged line number.
    ///   - source: The file's current text.
    /// - Returns: The updated source, or `source` unchanged when the marker
    ///   is already present at the location.
    /// - Throws: ``MarkerWriterError/lineOutOfRange(line:lineCount:)`` when
    ///   `line` does not address a content line.
    public static func apply(
        marker: String,
        reason: String? = nil,
        placement: MarkerPlacement = .endOfLine,
        toLine line: Int,
        inSource source: String
    ) throws -> String {
        var lines = source.components(separatedBy: "\n")
        let endsWithNewline = source.hasSuffix("\n")
        let contentLineCount = endsWithNewline ? lines.count - 1 : lines.count
        guard line >= 1, line <= contentLineCount else {
            throw MarkerWriterError.lineOutOfRange(line: line, lineCount: contentLineCount)
        }

        let index = line - 1
        if lines[index].contains(marker) { return source }
        if placement == .lineAbove, index > 0, lines[index - 1].contains(marker) { return source }

        let comment = commentText(marker: marker, reason: reason)
        var target = lines[index]
        let hadCarriageReturn = target.hasSuffix("\r")
        if hadCarriageReturn { target.removeLast() }
        let lineEnding = hadCarriageReturn ? "\r" : ""

        switch placement {
        case .endOfLine:
            while let last = target.last, last == " " || last == "\t" {
                target.removeLast()
            }
            let separator = target.isEmpty ? "" : " "
            lines[index] = target + separator + comment + lineEnding
        case .lineAbove:
            let indent = target.prefix { $0 == " " || $0 == "\t" }
            lines.insert(String(indent) + comment + lineEnding, at: index)
        }
        return lines.joined(separator: "\n")
    }

    /// Reads the file at `path`, applies the marker, and atomically writes
    /// the result back. A no-op (marker already present) leaves the file
    /// untouched.
    ///
    /// - Parameters:
    ///   - marker: The comment marker, including the leading `//`.
    ///   - reason: Optional human rationale (see ``apply(marker:reason:placement:toLine:inSource:)``).
    ///   - placement: Where to write the marker. Defaults to end-of-line.
    ///   - line: The 1-based flagged line number.
    ///   - path: Absolute path of the file to update.
    /// - Throws: ``MarkerWriterError`` for bad line numbers, or the underlying
    ///   file-system error from reading or writing the file.
    public static func applyToFile(
        marker: String,
        reason: String? = nil,
        placement: MarkerPlacement = .endOfLine,
        line: Int,
        path: String
    ) throws {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let updated = try apply(
            marker: marker, reason: reason, placement: placement, toLine: line, inSource: source)
        guard updated != source else { return }
        try updated.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The full comment to write: the marker, then the normalized reason as
    /// continuation text when one is given.
    static func commentText(marker: String, reason: String?) -> String {
        guard let normalized = normalizedReason(reason) else { return marker }
        return "\(marker) \(normalized)"
    }

    /// Collapses newlines to spaces and trims; blank reasons become nil so a
    /// marker never gains dangling whitespace.
    static func normalizedReason(_ reason: String?) -> String? {
        guard let reason else { return nil }
        let collapsed = reason
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.isEmpty ? nil : collapsed
    }
}
