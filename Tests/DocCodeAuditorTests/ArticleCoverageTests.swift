import QualityGateCore
import Testing
@testable import DocCodeAuditor

@Suite("Article coverage")
struct ArticleCoverageTests {

    private func verdict(
        found: Int, checked: Int, exempt: Int = 0, barrier: String? = nil,
        errors: [ArticleVerdict.CompileError] = []
    ) -> ArticleVerdict {
        ArticleVerdict(
            articlePath: "Doc.md",
            fencesFound: found,
            fencesChecked: checked,
            fencesExempt: exempt,
            exemptFenceLines: [],
            collisions: [],
            compileErrors: errors,
            barrier: barrier)
    }

    /// **The defect this proposal exists for, present in `doc-code` today.**
    ///
    /// `fencesChecked` is computed when the article is assembled — before the
    /// compiler runs. A `no such module` aborts compilation before typechecking, so
    /// when a barrier is reported *nothing* behind it was examined. The coverage
    /// line nonetheless said "12 checked", which is the exact shape of a fully
    /// examined article.
    @Test("A barriered article reports its fences as not analyzed, not as checked")
    func barrierMeansNotAnalyzed() {
        let coverage = verdict(found: 12, checked: 12, barrier: "no such module `Charts`").coverage
        #expect(coverage.examined == 0)
        #expect(coverage.notAnalyzedCount == 12)
        #expect(coverage.summary.contains("not analyzed"))
        #expect(coverage.summary.contains("Charts"))
    }

    @Test("A barriered article's coverage is not mistakable for a clean one")
    func barrierCoverageDiffersFromClean() {
        let barriered = verdict(found: 12, checked: 12, barrier: "no such module `Charts`").coverage
        let clean = verdict(found: 12, checked: 12).coverage
        #expect(barriered.summary != clean.summary)
    }

    @Test("An article with no barrier counts its checked fences as examined")
    func cleanArticleCountsAsExamined() {
        let coverage = verdict(found: 10, checked: 8, exempt: 2).coverage
        #expect(coverage.examined == 8)
        #expect(coverage.exempt == 2)
        #expect(coverage.notAnalyzedCount == 0)
        #expect(coverage.summary.contains("0 not analyzed"))
    }

    /// A failed compile is still an examined compile — the fences were typechecked
    /// and found wanting. Only a barrier means unexamined.
    @Test("Compile errors are examined, not unanalyzed")
    func compileErrorsAreExamined() {
        let coverage = verdict(
            found: 4, checked: 4,
            errors: [ArticleVerdict.CompileError(articleLine: 3, message: "boom")]).coverage
        #expect(coverage.examined == 4)
        #expect(coverage.notAnalyzedCount == 0)
    }

    @Test("An article with no Swift fences reports zero found")
    func noFencesFound() {
        let coverage = verdict(found: 0, checked: 0).coverage
        #expect(coverage.found == 0)
        #expect(coverage.examined == 0)
    }

    @Test("Coverage is stable across repeated derivation")
    func deterministic() {
        let subject = verdict(found: 6, checked: 6, barrier: "no such module `X`")
        #expect(subject.coverage.summary == subject.coverage.summary)
    }
}
