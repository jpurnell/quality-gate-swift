import Testing
@testable import QualityGateCore

@Suite("AnalysisOutcome")
struct AnalysisOutcomeTests {

    @Test("An unanalyzed unit is not counted as examined")
    func unanalyzedIsNotExamined() {
        #expect(AnalysisOutcome.analyzed.wasExamined)
        #expect(AnalysisOutcome.failed([]).wasExamined)
        #expect(!AnalysisOutcome.notAnalyzed(reason: "target not built here").wasExamined)
    }

    @Test("The reason survives onto the outcome")
    func reasonIsCarried() {
        let outcome = AnalysisOutcome.notAnalyzed(reason: "plugin not built")
        #expect(outcome.unanalyzedReason == "plugin not built")
        #expect(AnalysisOutcome.analyzed.unanalyzedReason == nil)
    }
}

@Suite("AnalysisCoverage")
struct AnalysisCoverageTests {

    /// The property the whole type exists for. Discovering no corpus is a statement
    /// about the checker's reach, not about the project, and it must not be spelled
    /// the way a clean run is spelled.
    @Test("Finding nothing to examine is an error, not a pass")
    func zeroCoverageIsAnError() {
        let coverage = AnalysisCoverage(unit: "fence", found: 0, examined: 0)
        let diagnostic = coverage.diagnostic(checkerId: "doc-code")
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.ruleId == "doc-code.no-coverage")
        #expect(diagnostic.message.contains("examined nothing"))
    }

    @Test("A hint is offered when there is no corpus")
    func zeroCoverageCarriesAHint() {
        let coverage = AnalysisCoverage(unit: "article", found: 0, examined: 0)
        let diagnostic = coverage.diagnostic(
            checkerId: "doc-code", corpusHint: "Add a .docc catalogue, or exclude doc-code.")
        #expect(diagnostic.suggestedFix?.contains("catalogue") == true)
    }

    /// Coverage prints on a clean run too, and says `0 not analyzed` explicitly
    /// rather than omitting the number. Absence of a line is what silence looks like.
    @Test("A fully examined corpus still prints coverage, including the zero")
    func cleanRunStillReportsCoverage() {
        let coverage = AnalysisCoverage(unit: "fence", found: 12, examined: 12)
        let diagnostic = coverage.diagnostic(checkerId: "doc-code")
        #expect(diagnostic.severity == .note)
        #expect(diagnostic.message.contains("12 found · 12 examined"))
        #expect(diagnostic.message.contains("0 not analyzed"))
    }

    /// Reasons are what a reader acts on: fourteen fences blocked for one reason is
    /// a fix, fourteen for fourteen reasons is an investigation.
    @Test("Unanalyzed units are reported grouped by reason")
    func reasonsAreGrouped() {
        let coverage = AnalysisCoverage(
            unit: "fence", found: 10, examined: 6,
            unanalyzed: ["target not built on this platform": 3, "plugin not built": 1])
        #expect(coverage.notAnalyzedCount == 4)
        #expect(coverage.summary.contains("4 not analyzed"))
        #expect(coverage.summary.contains("plugin not built (1)"))
        #expect(coverage.summary.contains("target not built on this platform (3)"))
    }

    /// Reasons are sorted, so the line does not depend on dictionary ordering. The
    /// whole string is asserted rather than its parts: a coverage line is read by
    /// people and diffed by tooling, and both care about the exact text.
    @Test("Reason order is stable across runs")
    func deterministicSummary() {
        let coverage = AnalysisCoverage(
            unit: "fence", found: 9, examined: 3,
            unanalyzed: ["zebra": 2, "alpha": 4])
        #expect(coverage.summary
            == "fences: 9 found · 3 examined · 6 not analyzed: alpha (4), zebra (2)")

        // Same content, opposite insertion order, identical output.
        let reordered = AnalysisCoverage(
            unit: "fence", found: 9, examined: 3,
            unanalyzed: ["alpha": 4, "zebra": 2])
        #expect(reordered.summary == coverage.summary)
    }

    @Test("Exempt units are reported separately from unanalyzed ones")
    func exemptIsNotUnanalyzed() {
        let coverage = AnalysisCoverage(unit: "fence", found: 10, examined: 8, exempt: 2)
        #expect(coverage.summary.contains("2 exempt"))
        #expect(coverage.notAnalyzedCount == 0)
        #expect(coverage.summary.contains("0 not analyzed"))
    }

    // MARK: - Derivation

    /// Coverage is derived from outcomes rather than tallied beside them, so the
    /// number cannot drift from the work it describes.
    @Test("Coverage is reduced from the outcomes themselves")
    func derivedFromOutcomes() {
        let outcomes: [AnalysisOutcome] = [
            .analyzed,
            .failed([Diagnostic(severity: .error, message: "boom", ruleId: "x")]),
            .notAnalyzed(reason: "target not built on this platform"),
            .notAnalyzed(reason: "target not built on this platform"),
        ]
        let coverage = outcomes.coverage(unit: "fence")
        #expect(coverage.found == 4)
        #expect(coverage.examined == 2)
        #expect(coverage.notAnalyzedCount == 2)
        #expect(coverage.unanalyzed["target not built on this platform"] == 2)
    }

    /// A checker may discover more units than it attempted. `found` then exceeds the
    /// outcome count, and the difference must not silently vanish.
    @Test("Found may exceed the outcomes attempted")
    func foundMayExceedAttempted() {
        let outcomes: [AnalysisOutcome] = [.analyzed, .analyzed]
        let coverage = outcomes.coverage(unit: "fence", found: 5, exempt: 3)
        #expect(coverage.found == 5)
        #expect(coverage.examined == 2)
        #expect(coverage.exempt == 3)
    }

    @Test("An empty outcome list yields zero coverage, which is an error")
    func emptyOutcomesAreAnError() {
        let coverage = [AnalysisOutcome]().coverage(unit: "fence")
        #expect(coverage.found == 0)
        #expect(coverage.diagnostic(checkerId: "doc-run").severity == .error)
    }
}
