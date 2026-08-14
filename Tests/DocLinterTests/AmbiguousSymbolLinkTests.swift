import Testing
@testable import DocLinter

@Suite("AmbiguousSymbolLink")
struct AmbiguousSymbolLinkTests {

    /// The motivating site from `DocSymbolLink.md` §4.3: a package that declares its
    /// own `Result` nested in `GitProvenance`, documented with a bare reference that
    /// a reader takes for the standard library's.
    private let local = ["Result": "GitProvenance/Result"]

    @Test("Fires on a bare reference that collides with the standard library")
    func firesOnCollision() {
        let findings = AmbiguousSymbolLink.findings(
            in: "The ``Result`` carries the outcome.", declaredLocally: local)
        #expect(findings.count == 1)
        #expect(findings.first?.name == "Result")
        #expect(findings.first?.localOwner == "GitProvenance/Result")
        #expect(findings.first?.line == 1)
    }

    /// The whole point of the rule is that the repair is unambiguous, so the already
    /// repaired form must be silent.
    @Test("Stays silent once the reference is qualified")
    func silentWhenQualified() {
        #expect(AmbiguousSymbolLink.findings(
            in: "The ``GitProvenance/Result`` carries the outcome.",
            declaredLocally: local).isEmpty)
    }

    /// A package with no `Result` of its own has no ambiguity — the bare reference
    /// resolves exactly where the reader expects, and flagging it would be noise
    /// about correct documentation.
    @Test("Stays silent when the package declares no colliding type")
    func silentWithoutLocalCollision() {
        #expect(AmbiguousSymbolLink.findings(
            in: "Returns a ``Result``.", declaredLocally: [:]).isEmpty)
    }

    @Test("Stays silent on a name the standard library does not define")
    func silentOnNonStdlibName() {
        #expect(AmbiguousSymbolLink.findings(
            in: "See ``ForecastErrorMetrics``.",
            declaredLocally: ["ForecastErrorMetrics": "ForecastErrorMetrics"]).isEmpty)
    }

    /// A reference carrying a signature or a disambiguator is already specific.
    @Test("Stays silent on signature-bearing and disambiguated references")
    func silentOnSpecificForms() {
        #expect(AmbiguousSymbolLink.findings(
            in: "See ``Result(catching:)`` and ``Result-4h4ny``.",
            declaredLocally: local).isEmpty)
    }

    @Test("Reports the line each reference appears on")
    func reportsLines() {
        let text = "# Title\n\nSome prose.\n\nThe ``Result`` value.\n"
        #expect(AmbiguousSymbolLink.findings(in: text, declaredLocally: local).first?.line == 5)
    }

    @Test("Finds several references on one line")
    func multiplePerLine() {
        let findings = AmbiguousSymbolLink.findings(
            in: "Either ``Result`` or ``Error`` may be returned.",
            declaredLocally: ["Result": "A/Result", "Error": "B/Error"])
        #expect(findings.map(\.name) == ["Result", "Error"])
    }

    /// Inline code spans are single-backtick and are not symbol links; a stray
    /// single backtick must not make the scanner swallow the rest of the line.
    @Test("Single-backtick code spans are not symbol references")
    func ignoresInlineCode() {
        #expect(AmbiguousSymbolLink.findings(
            in: "Use `Result` in prose, not as a link.", declaredLocally: local).isEmpty)
    }

    @Test("The diagnostic names both the local type and the repair")
    func diagnosticIsActionable() {
        let finding = AmbiguousSymbolLink.Finding(
            name: "Result", line: 3, localOwner: "GitProvenance/Result")
        let diagnostic = AmbiguousSymbolLink.diagnostic(for: finding, path: "Doc.md")
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.message.contains("GitProvenance/Result"))
        #expect(diagnostic.suggestedFix?.contains("``GitProvenance/Result``") == true)
        #expect(diagnostic.lineNumber == 3)
    }
}
