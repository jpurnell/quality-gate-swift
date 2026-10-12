import Foundation
import Testing
import QualityGateCore
@testable import SmellPack

/// Every smell reports the region it covers, not just where the region starts.
///
/// A smell is a claim about a *structure* — a type body, a closure, a parameter list — and the
/// structure has an extent. Reporting only its first line loses the size, which is the very
/// thing the rule measured: `smell.type-length` says "this type spans 400 lines" and then hands
/// the reader a point. A consumer counting flagged lines
/// (`ARatioNeedsAPopulation.md` in the companion) cannot reconstruct it.
///
/// `endLine` is never left absent here. Absence is reserved for rules that do not report a
/// region at all, so a consumer can exclude them and say which; a rule that *has* an extent and
/// omits it would be silently counted as one line.
@Suite("SmellPack spans")
struct SmellSpanTests {

    private func analyze(
        _ source: String,
        config: SmellConfig = SmellConfig()
    ) -> [Diagnostic] {
        SmellPack.analyze(source: source, filePath: "/fixtures/Fixture.swift", config: config).diagnostics
    }

    private func finding(_ ruleId: String, in diagnostics: [Diagnostic]) -> Diagnostic? {
        diagnostics.first { $0.ruleId == ruleId }
    }

    @Test("A long type body spans from its declaration to its closing brace")
    func typeLengthSpansTheBody() {
        let members = (1...12).map { "    let member\($0) = \($0)" }.joined(separator: "\n")
        let source = "struct Wide {\n\(members)\n}\n"
        let config = SmellConfig(maxTypeBodyLength: 5)

        guard let diagnostic = finding("smell.type-length", in: analyze(source, config: config)) else {
            Issue.record("expected a smell.type-length finding")
            return
        }
        // 1: `struct Wide {`, 2...13: the members, 14: `}`
        #expect(diagnostic.lineNumber == 1)
        #expect(diagnostic.endLine == 14)
        #expect(diagnostic.lineCount == 14)
    }

    @Test("A long closure spans from its declaration to its closing brace")
    func closureLengthSpansTheClosure() {
        let body = (1...10).map { "        _ = \($0)" }.joined(separator: "\n")
        let source = "func caller() {\n    run {\n\(body)\n    }\n}\n"
        let config = SmellConfig(maxClosureLength: 4)

        guard let diagnostic = finding("smell.closure-length", in: analyze(source, config: config)) else {
            Issue.record("expected a smell.closure-length finding")
            return
        }
        guard let span = diagnostic.lineSpan else {
            Issue.record("closure-length reported no span")
            return
        }
        // The closure's braces sit on lines 2 and 13; the rule already measures this extent to
        // decide whether to fire, so reporting it costs nothing.
        #expect(span.lowerBound == 2)
        #expect(span.upperBound == 13)
        #expect(diagnostic.lineCount == 12)
    }

    @Test("A long parameter list spans the whole signature")
    func parameterCountSpansTheSignature() {
        let source = """
        func wide(
            a: Int,
            b: Int,
            c: Int,
            d: Int,
            e: Int,
            f: Int
        ) {
            _ = a
        }
        """
        guard let diagnostic = finding("smell.parameter-count", in: analyze(source)) else {
            Issue.record("expected a smell.parameter-count finding")
            return
        }
        #expect(diagnostic.lineNumber == 1)
        guard let count = diagnostic.lineCount else {
            Issue.record("parameter-count reported no span")
            return
        }
        #expect(count > 1)
    }

    @Test("Every smell finding reports a span")
    func noSmellOmitsItsSpan() {
        let members = (1...12).map { "    let member\($0) = \($0)" }.joined(separator: "\n")
        let source = """
        struct Wide {
        \(members)
            func deep(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int) {
                if a > 0 {
                    if b > 0 {
                        if c > 0 {
                            if d > 0 {
                                if e > 0 { _ = f }
                            }
                        }
                    }
                }
            }
        }
        """
        let diagnostics = analyze(source, config: SmellConfig(maxTypeBodyLength: 5))
        #expect(diagnostics.count >= 3)
        // Named rather than counted: a failure should say which rule forgot, not that some
        // number did. `lineSpan` subsumes `endLine`, since a span needs one to exist.
        let withoutSpan = diagnostics.filter { $0.lineSpan == nil }.map { $0.ruleId ?? "?" }
        #expect(withoutSpan.isEmpty, "rules reporting no span: \(withoutSpan.joined(separator: ", "))")
    }

    @Test("A span never runs backwards, whatever the rule")
    func spansAreWellFormed() {
        let members = (1...12).map { "    let member\($0) = \($0)" }.joined(separator: "\n")
        let diagnostics = analyze("struct Wide {\n\(members)\n}\n", config: SmellConfig(maxTypeBodyLength: 5))
        for diagnostic in diagnostics {
            guard let line = diagnostic.lineNumber, let end = diagnostic.endLine else { continue }
            #expect(end >= line, "\(diagnostic.ruleId ?? "?") span runs backwards")
        }
    }
}
