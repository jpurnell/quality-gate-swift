import Foundation
import SwiftParser
import SwiftSyntax

/// Finds test functions whose `// TIMING:` marker sits on an assertion rather than above the
/// function.
///
/// The marker has two jobs. On a wall-clock assertion it tells `temporal-determinism` that the
/// threshold is intended; and it is supposed to enrol the test in stress runs, so that a
/// timing assumption someone has declared is also one that gets provoked. `TemporalScan`
/// documents both. Only the first happened: VigilKit's `TimingTestScanner` reads the comment
/// above the test function, so a marker written where the temporal rule asks for it — the
/// line of the assertion, or the line above — exempted the assertion and enrolled nothing.
///
/// This reads that second position, and is exactly as wide as the exemption: a comment
/// carrying the marker counts when it is on the first line of an assertion in a test
/// function's body, or on the line directly above it — the two lines the temporal rule
/// honours. The same text anywhere else enrols nothing: on a statement that is not an
/// assertion, in a string literal, or in a function that is not a test.
///
/// An assertion is `#expect`, `#require`, or a call to an `XCTAssert…` function.
enum AssertionTimingScanner {

    /// The names of test functions carrying `marker` on an assertion, in source order.
    ///
    /// - Parameters:
    ///   - source: Swift source text.
    ///   - marker: The comment marker (`// TIMING:` unless `stress.marker` says otherwise).
    /// - Returns: The tagged functions' base names.
    static func timingTests(in source: String, marker: String) -> [String] {
        guard source.contains(marker) else { return [] }
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "", tree: tree)
        let visitor = Visitor(marker: marker, converter: converter, viewMode: .sourceAccurate)
        visitor.walk(tree)
        return visitor.tagged
    }

    private final class Visitor: SyntaxVisitor {
        let marker: String
        let converter: SourceLocationConverter
        private(set) var tagged: [String] = []

        init(marker: String, converter: SourceLocationConverter, viewMode: SyntaxTreeViewMode) {
            self.marker = marker
            self.converter = converter
            super.init(viewMode: viewMode)
        }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            guard isTestFunction(node), let body = node.body else { return .visitChildren }

            let assertions = AssertionLines(converter: converter, viewMode: .sourceAccurate)
            assertions.walk(body)
            guard !assertions.lines.isEmpty else { return .visitChildren }

            let marked = markerLines(in: body)
            if assertions.lines.contains(where: { marked.contains($0) || marked.contains($0 - 1) }) {
                tagged.append(node.name.text)
            }
            return .visitChildren
        }

        /// `@Test`, or named `test…` — the same two shapes `TimingTestScanner` accepts.
        private func isTestFunction(_ node: FunctionDeclSyntax) -> Bool {
            if node.name.text.hasPrefix("test") { return true }
            return node.attributes.contains { element in
                element.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Test"
            }
        }

        /// The lines on which a comment carrying the marker starts.
        ///
        /// Read from trivia, so the marker inside a string literal is not found: that text is
        /// a token, not a comment.
        private func markerLines(in body: CodeBlockSyntax) -> Set<Int> {
            var lines: Set<Int> = []
            for token in body.tokens(viewMode: .sourceAccurate) {
                collect(token.leadingTrivia, startingAt: token.position, into: &lines)
                collect(token.trailingTrivia, startingAt: token.endPositionBeforeTrailingTrivia, into: &lines)
            }
            return lines
        }

        private func collect(_ trivia: Trivia, startingAt start: AbsolutePosition, into lines: inout Set<Int>) {
            var position = start
            for piece in trivia {
                if let comment = piece.commentText, comment.contains(marker) {
                    lines.insert(converter.location(for: position).line)
                }
                position = position.advanced(by: piece.sourceLength.utf8Length)
            }
        }
    }

    /// The first line of each assertion in a body.
    private final class AssertionLines: SyntaxVisitor {
        let converter: SourceLocationConverter
        private(set) var lines: Set<Int> = []

        init(converter: SourceLocationConverter, viewMode: SyntaxTreeViewMode) {
            self.converter = converter
            super.init(viewMode: viewMode)
        }

        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
            let name = node.macroName.text
            if name == "expect" || name == "require" { record(Syntax(node)) }
            return .visitChildren
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
               callee.baseName.text.hasPrefix("XCTAssert") {
                record(Syntax(node))
            }
            return .visitChildren
        }

        private func record(_ node: Syntax) {
            lines.insert(converter.location(for: node.positionAfterSkippingLeadingTrivia).line)
        }
    }
}

private extension TriviaPiece {
    /// The text of this piece when it is a comment of any kind.
    var commentText: String? {
        switch self {
        case .lineComment(let text), .blockComment(let text), .docLineComment(let text), .docBlockComment(let text):
            return text
        default:
            return nil
        }
    }
}
