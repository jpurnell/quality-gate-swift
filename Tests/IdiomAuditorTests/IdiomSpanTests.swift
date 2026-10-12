import Foundation
import Testing
import QualityGateCore
@testable import IdiomAuditor

/// Every idiom finding reports the region it covers.
///
/// The syntactic rules get this nearly free: `IdiomSyntaxVisitor.record(_:_:at:fix:)` already
/// receives the flagged node, and a node knows where it ends. The text rules each have to say
/// what their region is, and the answers are not uniform — which is the point of asserting
/// them rather than assuming.
///
/// Two are worth stating outright:
///
/// - `idiom.file-length` covers the lines **past the limit**, not the whole file. The rule's
///   claim is "there are more lines here than allowed"; the lines within the limit are not part
///   of what it objects to, and spanning them would make any consumer counting flagged lines
///   read a long file as almost entirely flagged.
/// - `idiom.vertical-whitespace` covers the whole excess blank run, which needs a lookahead the
///   rule did not previously do. Reporting only the first excess line would under-report a run
///   of ten by nine.
@Suite("IdiomAuditor spans")
struct IdiomSpanTests {

    private func diagnostics(
        _ source: String,
        config: IdiomConfig = IdiomConfig()
    ) -> [Diagnostic] {
        IdiomAuditor(config: config).auditSource(source, filePath: "/fixtures/Fixture.swift").diagnostics
    }

    private func finding(_ ruleId: String, in source: String, config: IdiomConfig = IdiomConfig()) -> Diagnostic? {
        diagnostics(source, config: config).first { $0.ruleId == ruleId }
    }

    // MARK: - Syntactic rules take their span from the flagged node

    @Test("A single-line syntactic finding spans exactly its own line")
    func singleLineSyntacticFinding() {
        let source = """
        func check(_ items: [Int]) -> Bool {
            items.count == 0
        }
        """
        guard let diagnostic = finding("idiom.empty-count", in: source) else {
            Issue.record("expected an idiom.empty-count finding")
            return
        }
        #expect(diagnostic.lineNumber == 2)
        #expect(diagnostic.endLine == 2)
        #expect(diagnostic.lineCount == 1)
    }

    @Test("A multi-line syntactic finding spans the whole flagged node")
    func multiLineSyntacticFinding() {
        let body = (1...40).map { "    _ = \($0)" }.joined(separator: "\n")
        let source = "func long() {\n\(body)\n}\n"
        let config = IdiomConfig(maxFunctionBodyLength: 10)

        guard let diagnostic = finding("idiom.function-body-length", in: source, config: config) else {
            Issue.record("expected an idiom.function-body-length finding")
            return
        }
        guard let count = diagnostic.lineCount else {
            Issue.record("function-body-length reported no span")
            return
        }
        #expect(diagnostic.lineNumber == 1)
        #expect(count > 1)
        #expect(diagnostic.endLine == 42)
    }

    // MARK: - Text rules say what their region is

    @Test("file-length covers the lines past the limit, not the whole file")
    func fileLengthCoversTheExcessOnly() {
        let source = (1...30).map { "let line\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let config = IdiomConfig(maxFileLength: 20)

        guard let diagnostic = finding("idiom.file-length", in: source, config: config) else {
            Issue.record("expected an idiom.file-length finding")
            return
        }
        #expect(diagnostic.lineNumber == 21)
        #expect(diagnostic.endLine == 30)
        #expect(diagnostic.lineCount == 10)
    }

    @Test("line-length spans one line")
    func lineLengthSpansOneLine() {
        let long = String(repeating: "x", count: 200)
        let source = "let value = \"\(long)\"\n"
        let config = IdiomConfig(maxLineLength: 100)

        guard let diagnostic = finding("idiom.line-length", in: source, config: config) else {
            Issue.record("expected an idiom.line-length finding")
            return
        }
        #expect(diagnostic.lineCount == 1)
    }

    @Test("vertical-whitespace covers the whole excess blank run")
    func verticalWhitespaceCoversTheRun() {
        // Line 1 is code; lines 2-8 are blank; line 9 is code.
        let source = "let a = 1\n" + String(repeating: "\n", count: 7) + "let b = 2\n"
        let config = IdiomConfig(maxConsecutiveBlankLines: 2)

        guard let diagnostic = finding("idiom.vertical-whitespace", in: source, config: config) else {
            Issue.record("expected an idiom.vertical-whitespace finding")
            return
        }
        // The run is lines 2-8; the first *excess* line is 4 (the third blank).
        #expect(diagnostic.lineNumber == 4)
        #expect(diagnostic.endLine == 8)
        #expect(diagnostic.lineCount == 5)
    }

    @Test("A blank run reaching end of file still reports a closed span")
    func verticalWhitespaceAtEndOfFile() {
        let source = "let a = 1\n" + String(repeating: "\n", count: 6)
        let config = IdiomConfig(maxConsecutiveBlankLines: 2)

        guard let diagnostic = finding("idiom.vertical-whitespace", in: source, config: config) else {
            Issue.record("expected an idiom.vertical-whitespace finding")
            return
        }
        guard let span = diagnostic.lineSpan else {
            Issue.record("vertical-whitespace reported no span at end of file")
            return
        }
        #expect(span.upperBound >= span.lowerBound)
    }

    // MARK: - No rule is silently absent

    @Test("Every idiom finding reports a span")
    func noIdiomRuleOmitsItsSpan() {
        let long = String(repeating: "x", count: 200)
        let source = """
        func check(_ items: [Int]) -> Bool {
            // TODO: no ticket here
            let value = "\(long)"
            _ = value
            return items.count == 0
        }
        """
        let found = diagnostics(source)
        #expect(found.count >= 2)
        // Named rather than counted: a failure should say which rule forgot, not that some
        // number did. `lineSpan` subsumes `endLine`, since a span needs one to exist.
        let withoutSpan = found.filter { $0.lineSpan == nil }.map { $0.ruleId ?? "?" }
        #expect(withoutSpan.isEmpty, "rules reporting no span: \(withoutSpan.joined(separator: ", "))")
    }
}
