import Foundation
import Testing
import QualityGateCore
@testable import DesignTokenDriftAuditor

@Suite("CSSDrift")
struct CSSDriftTests {

    private func hits(_ text: String, html: Bool = false) -> [String] {
        TokenFixtures.hits(CSSDrift.analyze(text: text, fileName: "x.css", isHTML: html, tokens: TokenFixtures.tokens))
    }

    @Test("Colour literals that are not tokens fire", arguments: [
        ".a { color: #E77500; }",
        ".a { color: #E75; }",
        ".a { color: #E77500CC; }",
        ".a { background: rgba(231, 117, 0, 0.5); }",
        ".a { background: rgb(231 117 0); }",
        ".a { color: hsl(30 100% 45%); }",
        ".a { color: oklch(0.7 0.2 50); }",
        ".a { border-color: #E77500 !important; }",
        ":root { --brand: #E77500; }",
        "@media (min-width: 600px) { .a { color: #E77500; } }",
        ".a { background: linear-gradient(#E77500, #FF8D28); }",
    ])
    func colourFires(css: String) {
        let found = hits(css)
        #expect(found.contains("design-token.css-colour:1"), "\(css) -> \(found)")
    }

    @Test("A colour that equals a token is a copy, with the variable to use")
    func tokenCopy() throws {
        let diagnostics = CSSDrift.analyze(
            text: ".a { color: #ff8d28; }", fileName: "x.css", isHTML: false, tokens: TokenFixtures.tokens)
        #expect(TokenFixtures.hits(diagnostics) == ["design-token.css-token-copy:1"])
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.suggestedFix?.contains("var(--accent)") == true)
    }

    @Test("A colour that is not a token names the nearest role")
    func nearestRole() throws {
        let diagnostics = CSSDrift.analyze(
            text: ".a { color: #E77500; }", fileName: "x.css", isHTML: false, tokens: TokenFixtures.tokens)
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.suggestedFix?.contains("var(--accent)") == true)
        #expect(diagnostic.suggestedFix?.contains("distance 52") == true)
    }

    @Test("Variables, keywords and selectors that look like hex stay quiet", arguments: [
        ".a { color: var(--accent); }",
        ".a { color: var(--accent, currentColor); }",
        ".a { color: transparent; }",
        ".a { color: currentColor; }",
        ".a { color: inherit; }",
        "#abc { margin: 0; }",
        "a#fff:hover { margin: 0; }",
        ".a { margin: 0; padding: 4px; }",
        "/* color: #E77500; */ .a { margin: 0; }",
        ".a { background: url(#E77500); }",
    ])
    func colourQuiet(css: String) {
        #expect(hits(css) == [], "\(css)")
    }

    @Test("Font sizes: literals not in the set fire, in-set literals are copies", arguments: [
        (".a { font-size: 14px; }", "design-token.css-font-size"),
        (".a { font-size: 0.875rem; }", "design-token.css-font-size"),
        (".a { font-size: 1.5em; }", "design-token.css-font-size"),
        (".a { font-size: clamp(1rem, 2vw, 3rem); }", "design-token.css-font-size"),
        (".a { font-size: 16px; }", "design-token.css-token-copy"),
        (".a { font-size: 1rem; }", "design-token.css-token-copy"),
        (".a { font-size: 28px; }", "design-token.css-token-copy"),
    ])
    func fontSize(css: String, rule: String) {
        #expect(hits(css) == ["\(rule):1"], "\(css)")
    }

    @Test("Font sizes from the tokens, keywords and percentages stay quiet", arguments: [
        ".a { font-size: var(--type-body-size); }",
        ".a { font-size: inherit; }",
        ".a { font-size: larger; }",
        ".a { font-size: 1em; }",
        ".a { font-size: 120%; }",
        ".a { font-size: calc(var(--type-body-size) * 1.2); }",
        ".a { font-weight: 700; line-height: 1.5; }",
    ])
    func fontSizeQuiet(css: String) {
        #expect(hits(css) == [], "\(css)")
    }

    @Test("A font-size finding names the nearest type role")
    func fontSizeNearest() throws {
        let diagnostics = CSSDrift.analyze(
            text: ".a { font-size: 14px; }", fileName: "x.css", isHTML: false, tokens: TokenFixtures.tokens)
        #expect(diagnostics.first?.suggestedFix?.contains("var(--type-caption-size)") == true)
    }

    @Test("Column widths: fixed tracks and wrong counts fire, token values are copies", arguments: [
        (".g { grid-template-columns: repeat(3, 1fr); }", "design-token.css-column"),
        (".g { grid-template-columns: 200px 1fr; }", "design-token.css-column"),
        (".g { grid-template-columns: minmax(0, 1fr) 300px; }", "design-token.css-column"),
        (".g { column-width: 240px; }", "design-token.css-column"),
        (".g { column-gap: 20px; }", "design-token.css-column"),
        (".g { gap: 2rem; }", "design-token.css-column"),
        (".g { grid-template-columns: repeat(12, 1fr); }", "design-token.css-token-copy"),
        (".g { column-gap: 16px; }", "design-token.css-token-copy"),
    ])
    func columns(css: String, rule: String) {
        #expect(hits(css) == ["\(rule):1"], "\(css)")
    }

    @Test("Token-driven and flexible columns stay quiet", arguments: [
        ".g { grid-template-columns: repeat(var(--columns), 1fr); }",
        ".g { grid-template-columns: 1fr 2fr; }",
        ".g { grid-template-columns: repeat(auto-fill, minmax(0, 1fr)); }",
        ".g { column-gap: var(--gutter); }",
        ".g { gap: var(--gutter); }",
        ".g { grid-column: 4 / 11; }",
        ".g { margin: 0 20px; }",
    ])
    func columnsQuiet(css: String) {
        #expect(hits(css) == [], "\(css)")
    }

    @Test("Lines are counted through comments and blank lines")
    func lines() {
        let css = """
        /* header
           spanning lines */

        .a {
          margin: 0;
          color: #E77500;
        }
        """
        #expect(hits(css) == ["design-token.css-colour:6"])
    }

    @Test("Two findings on one declaration block are reported separately, in order")
    func twoFindings() {
        let css = ".a {\n  color: #E77500;\n  font-size: 14px;\n}\n"
        #expect(hits(css) == ["design-token.css-colour:2", "design-token.css-font-size:3"])
    }

    // MARK: HTML

    @Test("HTML: style attributes, style blocks and SVG colour attributes fire", arguments: [
        #"<div style="color: #E77500">x</div>"#,
        "<style>.a{color:#E77500}</style>",
        ##"<rect fill="#E77500"/>"##,
        ##"<stop stop-color="#E77500"/>"##,
        #"<p style="font-size: 14px">x</p>"#,
    ])
    func htmlFires(html: String) {
        #expect(hits(html, html: true).count == 1, "\(html) -> \(hits(html, html: true))")
    }

    @Test("HTML: variables, anchors and ids stay quiet", arguments: [
        #"<p style="color: var(--accent)">x</p>"#,
        ##"<a href="#abc">x</a>"##,
        #"<div id="fff">x</div>"#,
        "<style>.a{color:var(--accent)}</style>",
        #"<rect fill="none"/>"#,
        ##"<script>var x = "#E77500";</script>"##,
    ])
    func htmlQuiet(html: String) {
        #expect(hits(html, html: true) == [], "\(html)")
    }

    @Test("HTML line numbers point at the right line")
    func htmlLines() {
        let html = "<html>\n<body>\n<div style=\"color: #E77500\">x</div>\n</body>\n</html>\n"
        #expect(hits(html, html: true) == ["design-token.css-colour:3"])
    }

    @Test("definesColour for a CSS palette file", arguments: [
        (":root { --brand: #E77500; }", true),
        (".a { color: rgb(1 2 3); }", true),
        (".a { color: var(--accent); }", false),
        ("", false),
    ])
    func definesColour(css: String, expected: Bool) {
        #expect(CSSDrift.definesColour(text: css, isHTML: false) == expected, "\(css)")
    }
}
