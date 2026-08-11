import Foundation
import QualityGateCore

/// Finds the claims in one fenced block, and works out what each is about.
///
/// Association is the part of rung 3 that the obvious design gets wrong. Measured over the
/// claim-carrying articles of one catalogue, resolving each claim to the statement it
/// follows:
///
/// | Anchor | Count |
/// | --- | --- |
/// | File-scope `let`/`var` binding | **81** |
/// | File-scope `print` | 14 |
/// | `print` nested in a closure or loop | 3 |
///
/// The dominant case, by a factor of five, is a claim about a value that is **never
/// printed**. A checker built on capturing stdout verifies 14 of 99 and reports success.
enum ClaimExtractor {

    /// Every claim in one block, with its anchor resolved.
    ///
    /// - Parameters:
    ///   - body: The block's lines, already dedented to file scope.
    ///   - firstArticleLine: Article line of `body[0]`.
    ///   - firstAssembledLine: Assembled line of `body[0]`, or `0` for an exempt block that
    ///     is not in the program at all.
    ///   - isExempt: Whether the block is marked `<!-- docs:illustrative -->`.
    /// - Returns: The claims, in document order.
    static func claims(
        inBlock body: [String], firstArticleLine: Int, firstAssembledLine: Int, isExempt: Bool
    ) -> [OutputClaim] {
        var found: [OutputClaim] = []
        for (offset, line) in body.enumerated() {
            guard let marker = OutputClaim.marker(in: line) else { continue }
            let resolved = anchor(in: body, at: offset)
            found.append(
                OutputClaim(
                    articleLine: firstArticleLine + offset,
                    kind: marker.kind,
                    body: marker.body,
                    anchor: resolved.anchor,
                    isExempt: isExempt,
                    assembledLine: isExempt ? 0 : firstAssembledLine + offset,
                    anchorAssembledLine: isExempt || resolved.offset < 0
                        ? 0
                        : firstAssembledLine + resolved.offset))
        }
        return found
    }

    /// What the claim at `index` is about, and which line carries it.
    ///
    /// Two things make this more than "look at the line above". The claim may be a trailing
    /// comment on the statement itself; and the statement above may be the *end* of a
    /// multi-line call, in which case the binding is several lines further up. The dominant
    /// shape in the corpus is
    ///
    /// ```
    /// let mortgage = payment(
    ///     principal: 300_000,
    ///     periods: 360
    /// )
    /// // Result: ~1,799
    /// ```
    ///
    /// where the line above the claim is a bare `)`. Anchoring to the nearest *line* rather
    /// than the nearest *statement* loses every one of these.
    ///
    /// - Returns: The anchor, and the block-relative offset of the statement it lives on, or
    ///   `-1` when there is none.
    static func anchor(in body: [String], at index: Int) -> (anchor: OutputClaim.Anchor, offset: Int) {
        // A trailing claim describes the statement it is written on.
        let ownLine = body[index]
        if let code = codeBefore(marker: ownLine), !code.isEmpty {
            return (statement(in: code) ?? .unanchored, index)
        }

        // Walk back over blank lines and other comments to the statement above.
        var cursor = index - 1
        while cursor >= 0 {
            let trimmed = body[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") {
                cursor -= 1
                continue
            }
            break
        }
        guard cursor >= 0 else { return (.unanchored, -1) }

        // Indented means nested — inside a closure, a loop or a type. The statement executes
        // an unknown number of times, so neither "the value of the binding" nor "the next
        // line of stdout" is well defined. Reported as unanchored rather than guessed at.
        guard body[cursor].first.map({ $0 != " " && $0 != "\t" }) == true else {
            return (.unanchored, -1)
        }

        // Walk back to the line that *opens* the statement: the last file-scope line at or
        // before the cursor that looks like a statement start. Everything between is a
        // continuation, including the closing `)` that sits at column 0.
        var start = cursor
        while start >= 0 {
            let line = body[start]
            if line.first.map({ $0 != " " && $0 != "\t" }) == true, let kind = statement(in: line) {
                return (kind, start)
            }
            start -= 1
        }
        return (.unanchored, -1)
    }

    /// The code preceding a claim marker on the same line, or `nil` when the line is all
    /// comment.
    static func codeBefore(marker line: String) -> String? {
        for (prefix, _) in OutputClaim.markers {
            guard let range = line.range(of: prefix) else { continue }
            return String(line[line.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The anchor a statement offers, or `nil` when it offers none.
    ///
    /// A destructuring `let (a, b) = …` deliberately offers none: there is no single name to
    /// read, and picking one would attach the claim to half a value.
    static func statement(in line: String) -> OutputClaim.Anchor? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("print(") { return .printStatement }

        for keyword in ["let ", "var "] {
            guard trimmed.hasPrefix(keyword) else { continue }
            let rest = trimmed.dropFirst(keyword.count).drop { $0 == " " }
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !name.isEmpty, name.first?.isNumber == false else { return nil }
            // It must actually be a binding: what follows the name is an assignment or a
            // type annotation. `let` inside a pattern-match condition is neither.
            let after = rest.dropFirst(name.count).drop { $0 == " " }
            guard after.hasPrefix("=") || after.hasPrefix(":") else { return nil }
            return .binding(String(name))
        }
        return nil
    }
}
