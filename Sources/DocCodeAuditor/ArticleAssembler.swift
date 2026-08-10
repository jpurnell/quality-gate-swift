import Foundation
import QualityGateCore

/// One article, concatenated into a single Swift program.
///
/// The compilation unit is the *article*: every checked block in document order, as one
/// file-scope program. That is not an implementation convenience — it is the convention
/// the corpus is held to. A later block that refers to an earlier binding is correct and
/// must keep working; two independent examples that both open with `let data = …` are a
/// defect in the article, and the repair is a rename, not an annotation.
public struct AssembledArticle: Sendable {

    /// The concatenated program.
    public let source: String

    /// Swift fences the article contains — checked plus exempt.
    ///
    /// Reported separately from ``fencesChecked`` on purpose. A gate that under-reports its
    /// own coverage is indistinguishable from a gate that passes, and that is exactly how
    /// six articles once passed with unchecked blocks in them.
    public let fencesFound: Int

    /// Swift fences that were compiled.
    public let fencesChecked: Int

    /// Swift fences skipped because the author marked them
    /// `<!-- docs:illustrative -->`.
    public let fencesExempt: Int

    /// The article line each exempt fence opens at, for reporting exemptions in place.
    public let exemptFenceLines: [Int]

    /// Assembled line of a block marker → article line of that block's first body line.
    let lineMap: [Int: Int]

    /// The article line corresponding to an assembled line.
    ///
    /// A diagnostic pointing at `/tmp/…/main.swift:12` is useless to whoever has to fix it:
    /// it sends them to a file that no longer exists. Resolution walks back to the nearest
    /// preceding block marker and adds the offset, so the reported line matches `grep` on
    /// the article.
    ///
    /// - Parameter assembled: A 1-indexed line in ``source``.
    /// - Returns: The 1-indexed article line, or `1` for the injected preamble, which
    ///   belongs to no block.
    public func articleLine(forAssembledLine assembled: Int) -> Int {
        var marker = 0
        var base = 0
        for (at, article) in lineMap where at <= assembled && at > marker {
            marker = at
            base = article
        }
        guard marker > 0 else { return 1 }
        return base + (assembled - marker) - 1
    }
}

/// Turns a markdown article into one compilable program.
public enum ArticleAssembler {

    /// The one opt-out. A fragment that was never meant to compile — a bare signature,
    /// pseudo-code, a deliberate counter-example, or a quoted excerpt of a type the module
    /// already defines.
    ///
    /// Written as an HTML comment rather than a fence info string because DocC passes an
    /// info string through as the block's *language identifier*: ` ```swift,illustrative `
    /// renders as an unknown language and silently costs syntax highlighting. The comment
    /// does not appear in the rendered page at all.
    ///
    /// It is never applied automatically. An auditor that reaches for its own opt-out is
    /// silencing the check rather than satisfying it.
    public static let illustrativeMarker = "<!-- docs:illustrative -->"

    /// Concatenates every checked Swift block of `markdown` into one program.
    ///
    /// Line-preserving by construction: an `import` that duplicates the preamble is
    /// *commented*, never removed, because deleting a line shifts every diagnostic after it
    /// and sends the reader to edit correct code.
    ///
    /// - Parameters:
    ///   - markdown: The article's full text.
    ///   - imports: Modules to import in the preamble — typically `Foundation` plus the
    ///     module the catalogue documents.
    /// - Returns: The assembled program with its coverage counts and line map.
    public static func assemble(_ markdown: String, imports: [String]) -> AssembledArticle {
        var out: [String] = imports.map { "import \($0)" }
        out.append("")

        var lineMap: [Int: Int] = [:]
        var found = 0
        var checked = 0
        var exempt = 0
        var exemptLines: [Int] = []
        var markerPending = false

        let preamble = Set(imports.map { "import \($0)" })
        let lines = markdown.lines
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == illustrativeMarker {
                markerPending = true
                index += 1
                continue
            }

            guard let fence = Fence(openingLine: line) else {
                // A pending marker survives blank lines and nothing else. Clearing it on any
                // non-fence line meant a marker separated from its block by a blank line was
                // silently dropped — and the block it exempted was then reported as broken.
                if !trimmed.isEmpty { markerPending = false }
                index += 1
                continue
            }

            // Consume the whole fence regardless of language, so a nested ```swift inside a
            // shell transcript is never mistaken for a block of its own.
            var body: [String] = []
            var cursor = index + 1
            while cursor < lines.count, !fence.closes(lines[cursor]) {
                body.append(dedent(lines[cursor], by: fence.indent))
                cursor += 1
            }

            if fence.isSwift {
                found += 1
                if markerPending {
                    exempt += 1
                    exemptLines.append(index + 1)
                } else {
                    checked += 1
                    // 1-indexed article line of `body[0]`: the fence opens at `index + 1`.
                    lineMap[out.count + 1] = index + 2
                    out.append("// >>> article line \(index + 2)")
                    out.append(contentsOf: body.map { statement in
                        preamble.contains(statement.trimmingCharacters(in: .whitespaces))
                            ? "// " + statement
                            : statement
                    })
                    out.append("")
                }
            }

            markerPending = false
            index = cursor + 1
        }

        return AssembledArticle(
            source: out.joined(separator: "\n") + "\n",
            fencesFound: found,
            fencesChecked: checked,
            fencesExempt: exempt,
            exemptFenceLines: exemptLines,
            lineMap: lineMap)
    }

    /// Removes up to `count` leading spaces or tabs, leaving deeper indentation intact.
    ///
    /// A fence nested in a list item carries the list's indentation on every body line.
    /// Stripping exactly the fence's own indent keeps the block's internal structure while
    /// putting its outermost statements back at file scope, where the convention needs them.
    static func dedent(_ line: String, by count: Int) -> String {
        var remaining = count
        var index = line.startIndex
        while remaining > 0, index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
            remaining -= 1
        }
        return String(line[index...])
    }
}

/// A fenced code block's opening line: its indentation, its delimiter, and its language.
struct Fence {

    /// Leading whitespace characters, which the body inherits.
    let indent: Int

    /// The backtick or tilde run that opens — and must close — the block.
    let delimiter: String

    /// Whether the info string names Swift.
    let isSwift: Bool

    /// Parses `line` as a fence opener, or returns `nil` if it is prose.
    init?(openingLine line: String) {
        let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
        let fenceCharacter: Character
        if stripped.hasPrefix("```") {
            fenceCharacter = "`"
        } else if stripped.hasPrefix("~~~") {
            fenceCharacter = "~"
        } else {
            return nil
        }

        let run = stripped.prefix(while: { $0 == fenceCharacter })
        indent = line.count - stripped.count
        delimiter = String(run)

        // Match the language *token*, not a prefix. `hasPrefix("```swift")` also matches
        // ```swiftui and ```swift-output, and compiling those produces findings about a
        // language the block never claimed to be written in.
        let info = stripped.dropFirst(run.count)
        let language = info.prefix { !$0.isWhitespace && $0 != "," && $0 != "{" }
        isSwift = language.lowercased() == "swift"
    }

    /// Whether `line` closes this fence.
    func closes(_ line: String) -> Bool {
        let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = delimiter.first else { return false }
        return stripped.prefix(while: { $0 == first }).count >= delimiter.count
    }
}
