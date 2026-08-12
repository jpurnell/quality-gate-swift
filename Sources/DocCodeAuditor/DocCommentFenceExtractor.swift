import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// One fenced code block found inside a `///` or `/** */` doc comment.
///
/// The compilation unit of `doc-comment-code`. Not the doc comment, and emphatically not the
/// file: `HIGAuditor.swift` carries one `///` run holding two unrelated fences — a usage
/// example and a fragment of the *reader's* SwiftUI code — separated by a heading. They share
/// a doc comment and nothing else. Concatenating them would buy no shared bindings and would
/// import `doc-code`'s collision rule into a place where its premise — *an article is one
/// program, pasted into a playground end to end* — is simply false. Nobody pastes a Quick
/// Help panel.
public struct DocCommentFence: Sendable, Equatable {

    /// Path of the `.swift` file the doc comment lives in.
    public let filePath: String

    /// 1-indexed line of the fence's opening delimiter, in the `.swift` file.
    ///
    /// Not in the doc comment, and not in the temporary program: a diagnostic that points
    /// anywhere else sends the reader to a file that no longer exists.
    public let openLine: Int

    /// The info string's language token, lowercased. Empty when the fence is untagged.
    public let language: String

    /// The fence body with the doc-comment prefix stripped and the fence's own indentation
    /// removed, ready to compile as file-scope Swift.
    public let body: [String]

    /// Whether `<!-- docs:illustrative -->` immediately precedes the fence.
    public let isExempt: Bool

    /// Name of the declaration the doc comment is attached to, for the diagnostic.
    public let declarationName: String?

    /// Access level of that declaration — `public`, `internal`, and so on.
    ///
    /// Recorded and deliberately unspent. A `///` on an `internal` declaration whose example
    /// uses internal API cannot compile against the built `.swiftmodule`, which exposes only
    /// the public surface. Incidence of that class in this repository is 0 of 20, so
    /// narrowing on it now would be scoping on a hazard nobody has observed — but the
    /// extractor already knows the answer, so the mitigation stays one line away.
    public let accessLevel: String?

    /// Whether the info string names Swift, and therefore whether the fence is compiled.
    public var isSwift: Bool { language == "swift" }

    /// Whether this fence is one the checker will compile.
    public var isCheckable: Bool { isSwift && !isExempt }
}

/// What one file's doc comments contain, pass or fail.
///
/// Reported in full — found, checked, exempt, and skipped-as-not-Swift — because a gate that
/// under-reports its own coverage is indistinguishable from a gate that passes. An untagged
/// fence that later fills with Swift shows up as a count that did not move while a file's
/// examples did, and that is the only warning anyone gets.
public struct DocCommentCensus: Sendable {

    /// Path of the file surveyed.
    public let filePath: String

    /// Every fence found, in document order, whatever its language.
    public let fences: [DocCommentFence]

    /// Fences of any language.
    public var found: Int { fences.count }

    /// Swift fences the checker will compile.
    public var checkable: [DocCommentFence] { fences.filter(\.isCheckable) }

    /// Number of Swift fences compiled.
    public var checked: Int { checkable.count }

    /// Swift fences the author marked `<!-- docs:illustrative -->`.
    public var exempt: Int { fences.filter { $0.isSwift && $0.isExempt }.count }

    /// Fences whose language token is not `swift`, including untagged ones.
    public var notSwift: Int { fences.count { !$0.isSwift } }

    /// The distinct non-Swift language tokens present, sorted, with untagged fences named.
    ///
    /// An untagged fence is never guessed at. Both of the ones in this repository are prose
    /// diagrams that would produce a wall of parse errors if compiled, and guessing at them
    /// is the `swiftui`-fence bug with its sign flipped.
    public var foreignLanguages: [String] {
        Set(fences.filter { !$0.isSwift }
            .map { $0.language.isEmpty ? "(untagged)" : $0.language }).sorted()
    }

    /// The coverage line, in the shape `doc-code` already uses.
    public var coverageMessage: String {
        var message = "\(found) doc fences: \(checked) checked, \(exempt) exempt, \(notSwift) not Swift"
        if !foreignLanguages.isEmpty {
            message += " (\(foreignLanguages.joined(separator: ", ")))"
        }
        return message
    }
}

/// Finds the fenced code blocks inside a Swift file's doc comments.
///
/// Extraction is via SwiftSyntax trivia, never a line scan, and that is not a preference.
/// A naive `^\s*///.*```swift` reports 21 swift doc fences in this package; the strict count
/// is 20. The difference is `ArticleAssembler.swift:66` — an inline code span in prose, in
/// the sentence explaining why the illustrative marker is an HTML comment. A regex extractor
/// would try to compile the remainder of that doc comment and report the errors as
/// documentation defects, in the file that documents the rule.
///
/// The tree gives three more things a scanner cannot:
///
/// - **Doc comments are trivia attached to a token.** A `///` sequence inside a multi-line
///   string literal is token text, not trivia, so a markdown fixture in a test file can never
///   be mistaken for documentation.
/// - **The attached declaration**, hence its name for the diagnostic and its access level for
///   the mitigation that is not yet spent.
/// - **No new dependency.** Thirty-four files in this package already call `Parser.parse`.
public enum DocCommentFenceExtractor {

    /// One doc-comment body line, and the file line it came from.
    struct CommentLine {
        /// 1-indexed line in the `.swift` file.
        let fileLine: Int
        /// The line with its `///` or `*` prefix removed.
        let text: String
    }

    /// Every fence in every doc comment of `source`.
    ///
    /// - Parameters:
    ///   - source: The Swift file's full text.
    ///   - path: The file's path, carried into each fence for reporting.
    /// - Returns: The fences in document order.
    public static func fences(in source: String, path: String) -> [DocCommentFence] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        var found: [DocCommentFence] = []

        for token in tree.tokens(viewMode: .sourceAccurate) {
            var position = token.position
            var run: [CommentLine] = []

            /// Closes the run in progress, scanning whatever it accumulated.
            func flush() {
                guard !run.isEmpty else { return }
                found += scan(run, path: path, token: token)
                run = []
            }

            for piece in token.leadingTrivia {
                switch piece {
                case .docLineComment(let text):
                    let line = converter.location(for: position).line
                    run.append(CommentLine(fileLine: line, text: stripDocLinePrefix(text)))
                case .docBlockComment(let text):
                    flush()
                    let line = converter.location(for: position).line
                    found += scan(
                        blockCommentLines(text, startingAt: line), path: path, token: token)
                case .newlines(let count), .carriageReturnLineFeeds(let count):
                    // A blank line ends the run. Two `///` paragraphs separated by an empty
                    // line are two doc comments to the reader and two to DocC, and joining
                    // them would let a marker in the first exempt a fence in the second.
                    if count > 1 { flush() }
                case .spaces, .tabs:
                    break
                default:
                    // Any other trivia — an ordinary `//` comment, a `#if` region's text —
                    // breaks the run. A `//` comment containing a fence is scratch, not
                    // documentation.
                    flush()
                }
                position += piece.sourceLength
            }
            flush()
        }

        return found
    }

    /// Every fence in every doc comment of the file at `url`.
    ///
    /// - Parameter url: A `.swift` file.
    /// - Returns: The fences in document order.
    /// - Throws: If the file cannot be read as UTF-8.
    public static func fences(inFileAt url: URL) throws -> [DocCommentFence] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return fences(in: text, path: url.path)
    }

    /// The census for one file's source text.
    public static func census(in source: String, path: String) -> DocCommentCensus {
        DocCommentCensus(filePath: path, fences: fences(in: source, path: path))
    }

    // MARK: - Prefix stripping

    /// Removes `///` and at most one following space.
    ///
    /// One space, because markdown's own indentation is significant: a fence nested in a list
    /// item carries the list's indentation, and eating it would put the block back at column
    /// zero and lose the structure ``ArticleAssembler/dedent(_:by:)`` exists to preserve.
    static func stripDocLinePrefix(_ text: String) -> String {
        var body = Substring(text)
        guard body.hasPrefix("///") else { return text }
        body = body.dropFirst(3)
        if body.hasPrefix(" ") { body = body.dropFirst() }
        return String(body)
    }

    /// Splits a `/** */` doc comment into body lines, stripping `*` continuation markers only
    /// when the comment actually uses them.
    ///
    /// The decision is per comment, not per line, and that is the whole point. Stripping a
    /// leading `*` unconditionally would eat the first character of a body line that
    /// legitimately begins with one — a pointer dereference, a glob — in a comment that never
    /// used continuation markers at all. There is no `/** */` doc comment anywhere in this
    /// package, so nothing but a fixture stands behind this path.
    static func blockCommentLines(_ text: String, startingAt startLine: Int) -> [CommentLine] {
        var raw = text.lines
        guard !raw.isEmpty else { return [] }

        if raw[0].hasPrefix("/**") { raw[0] = String(raw[0].dropFirst(3)) }
        if let last = raw.indices.last, raw[last].hasSuffix("*/") {
            raw[last] = String(raw[last].dropLast(2))
        }

        // A marker line is whitespace, then `*`. If every non-blank interior line is one,
        // they are decoration; otherwise they are content.
        let interior = raw.dropFirst().dropLast()
        let candidates = interior.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let usesMarkers = !candidates.isEmpty
            && candidates.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("*") }

        return raw.enumerated().map { offset, line in
            CommentLine(
                fileLine: startLine + offset,
                text: usesMarkers ? stripContinuationMarker(line) : line)
        }
    }

    /// Removes leading whitespace, exactly one `*`, and at most one following space.
    static func stripContinuationMarker(_ line: String) -> String {
        var body = Substring(line).drop(while: { $0 == " " || $0 == "\t" })
        guard body.hasPrefix("*") else { return line }
        body = body.dropFirst()
        if body.hasPrefix(" ") { body = body.dropFirst() }
        return String(body)
    }

    // MARK: - Fence scanning

    /// Finds the fences in one doc comment's body lines.
    ///
    /// `Fence` is reused verbatim from ``ArticleAssembler`` — including its language-*token*
    /// match, which `doc-code` earned by shipping the `swiftui`-fence bug once — and so
    /// is the marker's "survives blank lines and nothing else" rule. Two spellings of that
    /// rule would mean two implementations, and one of them would drift.
    static func scan(_ lines: [CommentLine], path: String, token: TokenSyntax) -> [DocCommentFence] {
        var found: [DocCommentFence] = []
        var markerPending = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)

            if trimmed == ArticleAssembler.illustrativeMarker {
                markerPending = true
                index += 1
                continue
            }

            guard let fence = Fence(openingLine: line.text) else {
                if !trimmed.isEmpty { markerPending = false }
                index += 1
                continue
            }

            // Consume the whole fence whatever its language, so a nested ```swift inside a
            // shell transcript is never mistaken for a block of its own.
            var body: [String] = []
            var cursor = index + 1
            while cursor < lines.count, !fence.closes(lines[cursor].text) {
                body.append(ArticleAssembler.dedent(lines[cursor].text, by: fence.indent))
                cursor += 1
            }

            found.append(
                DocCommentFence(
                    filePath: path,
                    openLine: line.fileLine,
                    language: fence.language,
                    body: body,
                    isExempt: markerPending,
                    declarationName: Self.declarationName(for: token),
                    accessLevel: Self.accessLevel(for: token)))

            markerPending = false
            index = cursor + 1
        }

        return found
    }

    // MARK: - The attached declaration

    /// The name of the nearest enclosing declaration, for the diagnostic.
    ///
    /// Best effort by design: a doc comment that attaches to nothing — a trailing comment
    /// before a closing brace — still yields its fences, and the diagnostic simply names the
    /// file and line instead.
    static func declarationName(for token: TokenSyntax) -> String? {
        var node: Syntax? = Syntax(token)
        while let current = node {
            if let named = current.asProtocol(NamedDeclSyntax.self) { return named.name.text }
            if current.is(InitializerDeclSyntax.self) { return "init" }
            if let variable = current.as(VariableDeclSyntax.self) {
                return variable.bindings.first?.pattern.trimmedDescription
            }
            if let extended = current.as(ExtensionDeclSyntax.self) {
                return extended.extendedType.trimmedDescription
            }
            node = current.parent
        }
        return nil
    }

    /// The declared access level of the nearest enclosing declaration, or `nil` when it is
    /// implicit.
    static func accessLevel(for token: TokenSyntax) -> String? {
        let levels: Set<String> = ["open", "public", "package", "internal", "fileprivate", "private"]
        var node: Syntax? = Syntax(token)
        while let current = node {
            if let declaration = current.asProtocol(WithModifiersSyntax.self) {
                if let modifier = declaration.modifiers.first(where: {
                    levels.contains($0.name.text)
                }) {
                    return modifier.name.text
                }
                if current.isProtocol(DeclSyntaxProtocol.self) { return nil }
            }
            node = current.parent
        }
        return nil
    }
}
