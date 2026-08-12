import Foundation
import QualityGateCore

/// Rewrites a stale region's body, and nothing else in the file.
///
/// ## Why this does not split the file into lines and join it back
///
/// The obvious implementation — `contents.lines`, replace the slice, `joined(separator: "\n")` —
/// silently rewrites every line ending in the file. On a CRLF document it would convert the
/// whole file to LF while "fixing" three rows, which is precisely the constraint this fix is
/// held to: *only the bytes strictly between the delimiters change, not the delimiters, and not
/// one byte outside them*.
///
/// So the body is located as a character range and replaced in place. Everything before the
/// opening delimiter's newline and everything from the closing delimiter's line onward is
/// carried through untouched, whatever it contains.
enum RegionFixer {

    /// Replaces one region's body, leaving every other byte of the file alone.
    ///
    /// - Parameters:
    ///   - contents: The governed file, as it is on disk.
    ///   - id: The region's generator id, which both delimiters name.
    ///   - generated: The body the generator produced, with no trailing newline.
    /// - Returns: The rewritten file, or `nil` when the delimiters cannot be located — in which
    ///   case nothing is written and `check` keeps reporting the region.
    static func replacingBody(in contents: String, id: String, with generated: String) -> String? {
        let open = "<!-- generated:\(id) -->"
        let close = "<!-- /generated:\(id) -->"

        guard let openRange = contents.range(of: open),
              let closeRange = contents.range(
                of: close, range: openRange.upperBound..<contents.endIndex),
              let newlineAfterOpen = contents[openRange.upperBound...]
                .firstIndex(where: \.isNewline)
        else {
            return nil
        }

        let bodyStart = contents.index(after: newlineAfterOpen)
        // The closing delimiter owns its line, so the body ends where that line begins.
        let bodyEnd: String.Index
        if let previousNewline = contents[..<closeRange.lowerBound].lastIndex(where: \.isNewline) {
            bodyEnd = contents.index(after: previousNewline)
        } else {
            bodyEnd = contents.startIndex
        }
        guard bodyStart <= bodyEnd else { return nil }

        // The body is written in the file's own line ending. Terminating generated rows with
        // `\n` inside a CRLF document would satisfy the letter of "only the bytes between the
        // delimiters change" and still leave the file with two conventions in it — which is
        // the kind of diff that makes a reviewer distrust the tool that produced it.
        let newline = contents.contains("\r\n") ? "\r\n" : "\n"

        // An empty region is delimiters on consecutive lines: no body, and so no newline either.
        let replacement = generated.isEmpty
            ? ""
            : generated.lines.joined(separator: newline) + newline
        return contents.replacingCharacters(in: bodyStart..<bodyEnd, with: replacement)
    }
}
