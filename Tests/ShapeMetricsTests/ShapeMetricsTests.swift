import Foundation
import Testing
import ComplexityAnalyzer
import QualityGateCore
@testable import ShapeMetrics

/// The aggregation that turns findings into two codebase-shape ratios.
///
/// These are §5 tests 1–10 of `ARatioNeedsAPopulation.md`. The values are computed by hand,
/// because a metric whose expected values are produced by the code under test asserts only that
/// the code is consistent with itself.
@Suite("ShapeMetrics")
struct ShapeMetricsTests {

    private let fileA = "/fixtures/A.swift"
    private let fileB = "/fixtures/B.swift"

    /// A profile whose source lines are `1...count`.
    private func solidProfile(_ count: Int) -> SLOCProfile {
        SLOCProfile(codeLines: Set(1...count))
    }

    /// Unwraps a report, failing the test rather than substituting a value.
    ///
    /// A `?? 0` in an assertion turns "there was no report" into "the report said zero", which
    /// is the `coalesced-assertion` rule's whole complaint — and it was right about these.
    private func require(
        _ report: VerbosityReport?,
        _ sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> VerbosityReport {
        try #require(report, "expected a verbosity report", sourceLocation: sourceLocation)
    }

    private func region(_ ruleId: String, _ span: ClosedRange<Int>, in file: String? = nil) -> FlaggedRegion {
        FlaggedRegion(ruleId: ruleId, filePath: file ?? fileA, span: span)
    }

    private func function(cc: Int, lines: Int, startLine: Int = 1) -> FunctionComplexityRecord {
        FunctionComplexityRecord(
            functionName: "f",
            moduleName: "M",
            filePath: fileA,
            startLine: startLine,
            endLine: startLine + lines - 1,
            cognitiveComplexity: cc,
            cognitiveBreakdown: [],
            cyclomaticComplexity: cc
        )
    }

    // MARK: - 1. Union, not sum

    @Test("A line flagged by two rules counts once")
    func unionNotSum() {
        let report = ShapeMetrics.verbosity(
            regions: [
                region("idiom.empty-count", 10...19),
                region("duplication.clone", 10...19),
            ],
            sloc: [fileA: solidProfile(100)],
            config: ShapeConfig()
        )
        guard let report else {
            Issue.record("expected a verbosity report")
            return
        }
        // Ten distinct lines, flagged twice.
        #expect(abs(report.verbosity - 0.10) < 1e-9)
        #expect(abs(report.idiom - 0.10) < 1e-9)
        #expect(abs(report.clone - 0.10) < 1e-9)
        // Summing the components would have given 0.20; the excess is exactly the overlap.
        #expect(abs(report.overlap - 0.10) < 1e-9)
    }

    @Test("Independent regions do not overlap")
    func disjointRegionsHaveNoOverlap() throws {
        let report = ShapeMetrics.verbosity(
            regions: [
                region("idiom.empty-count", 1...10),
                region("duplication.clone", 21...30),
            ],
            sloc: [fileA: solidProfile(100)],
            config: ShapeConfig()
        )
        let unwrapped = try require(report)
        #expect(abs(unwrapped.verbosity - 0.20) < 1e-9)
        #expect(abs(unwrapped.overlap) < 1e-9)
    }

    @Test("The same line number in two files is two lines, not one")
    func linesAreScopedToTheirFile() throws {
        let report = ShapeMetrics.verbosity(
            regions: [
                region("idiom.empty-count", 5...5, in: fileA),
                region("idiom.empty-count", 5...5, in: fileB),
            ],
            sloc: [fileA: solidProfile(50), fileB: solidProfile(50)],
            config: ShapeConfig()
        )
        // 2 lines of 100, not 1.
        #expect(abs(try require(report).verbosity - 0.02) < 1e-9)
    }

    // MARK: - 2 & 3. Spans are honoured, and only over real source lines

    @Test("A multi-line span contributes every line it covers")
    func spansContributeTheirWholeExtent() throws {
        let report = ShapeMetrics.verbosity(
            regions: [region("idiom.redundant-nil-coalescing", 1...40)],
            sloc: [fileA: solidProfile(100)],
            config: ShapeConfig()
        )
        #expect(abs(try require(report).verbosity - 0.40) < 1e-9)
    }

    @Test("Blank and comment lines inside a span count in neither numerator nor denominator")
    func nonSourceLinesAreExcluded() {
        // Lines 1-10 exist; only the odd ones carry code.
        let profile = SLOCProfile(codeLines: Set(stride(from: 1, through: 9, by: 2)))
        let report = ShapeMetrics.verbosity(
            regions: [region("idiom.empty-count", 1...10)],
            sloc: [fileA: profile],
            config: ShapeConfig()
        )
        guard let report else {
            Issue.record("expected a verbosity report")
            return
        }
        #expect(report.sloc == 5)
        // The span covers ten lines but only five are source, so the ratio is 1.0 — not 2.0.
        #expect(abs(report.verbosity - 1.0) < 1e-9)
    }

    @Test("Both ratios stay within [0, 1] under maximal overlap")
    func ratiosAreBounded() {
        let report = ShapeMetrics.verbosity(
            regions: (1...20).map { _ in region("idiom.empty-count", 1...100) },
            sloc: [fileA: solidProfile(100)],
            config: ShapeConfig()
        )
        guard let report else {
            Issue.record("expected a verbosity report")
            return
        }
        #expect(report.verbosity >= 0 && report.verbosity <= 1)
        #expect(abs(report.verbosity - 1.0) < 1e-9)
    }

    // MARK: - Size claims are measured, but not in the headline

    @Test("A size rule is reported as its own component and kept out of the headline")
    func sizeClaimsAreExcludedFromTheHeadline() {
        let report = ShapeMetrics.verbosity(
            regions: [
                region("smell.type-length", 1...80),
                region("idiom.empty-count", 90...99),
            ],
            sloc: [fileA: solidProfile(100)],
            config: ShapeConfig()
        )
        guard let report else {
            Issue.record("expected a verbosity report")
            return
        }
        // The 80-line type would otherwise have made this file 0.90 verbose on its own.
        #expect(abs(report.verbosity - 0.10) < 1e-9)
        #expect(abs(report.sizeClaims - 0.80) < 1e-9)
    }

    @Test("Configuring the size set empty puts those rules back in the headline")
    func sizeExclusionIsConfigurable() throws {
        let report = ShapeMetrics.verbosity(
            regions: [region("smell.type-length", 1...80)],
            sloc: [fileA: solidProfile(100)],
            config: ShapeConfig(sizeRules: [])
        )
        #expect(abs(try require(report).verbosity - 0.80) < 1e-9)
    }

    @Test("A headline can be resolved to the rules that caused it")
    func perRuleSharesAreReported() throws {
        let report = ShapeMetrics.verbosity(
            regions: [
                region("idiom.empty-count", 1...10),
                region("idiom.syntactic-sugar", 21...40),
            ],
            sloc: [fileA: solidProfile(100)],
            config: ShapeConfig()
        )
        let byRule = try require(report).byRule
        let sugar = try #require(byRule["idiom.syntactic-sugar"])
        let emptyCount = try #require(byRule["idiom.empty-count"])
        #expect(abs(sugar - 0.20) < 1e-9)
        #expect(abs(emptyCount - 0.10) < 1e-9)
    }

    // MARK: - 4 & 5. Mass weighting, and what it separates

    @Test("mass(f) = CC(f)·√SLOC(f)")
    func massIsComplexityTimesRootLength() {
        // CC 20 over 100 lines: 20 · 10 = 200.
        #expect(abs(ShapeMetrics.mass(of: function(cc: 20, lines: 100)) - 200.0) < 1e-9)
        // CC 2 over 10 lines: 2 · √10.
        let expected = 2.0 * 10.0.squareRoot()
        #expect(abs(ShapeMetrics.mass(of: function(cc: 2, lines: 10)) - expected) < 1e-9)
    }

    @Test("Erosion is mass-weighted, and differs from the unweighted count share")
    func erosionIsMassWeighted() {
        // One CC-20 100-liner (mass 200) and ten CC-2 10-liners (mass 2√10 ≈ 6.3246 each).
        var functions = [function(cc: 20, lines: 100)]
        functions += (1...10).map { _ in function(cc: 2, lines: 10) }

        guard let report = ShapeMetrics.erosion(functions: functions, threshold: 10) else {
            Issue.record("expected an erosion report")
            return
        }
        let heavy = 200.0
        let light = 10.0 * 2.0 * 10.0.squareRoot()
        #expect(abs(report.erosion - heavy / (heavy + light)) < 1e-9)
        // One of eleven functions is over the threshold...
        #expect(abs(report.countShare - 1.0 / 11.0) < 1e-9)
        // ...but it carries three quarters of the mass. The gap is the point.
        #expect(report.erosion > report.countShare * 3)
    }

    @Test("A few monsters and many medium functions are told apart")
    func massShareSeparatesTheTwoShapes() {
        let fewMonsters = [function(cc: 40, lines: 400)] + (1...20).map { _ in function(cc: 3, lines: 15) }
        let pervasive = (1...21).map { _ in function(cc: 11, lines: 30) }

        guard let monsters = ShapeMetrics.erosion(functions: fewMonsters, threshold: 10),
              let spread = ShapeMetrics.erosion(functions: pervasive, threshold: 10) else {
            Issue.record("expected both erosion reports")
            return
        }
        // Both are badly eroded by mass...
        #expect(monsters.erosion > 0.5)
        #expect(spread.erosion > 0.5)
        // ...and only the count share says which kind of problem it is.
        #expect(monsters.countShare < 0.10)
        #expect(abs(spread.countShare - 1.0) < 1e-9)
    }

    // MARK: - 6. Empty is not zero

    @Test("A package with no functions has no erosion, not zero erosion")
    func noFunctionsMeansNoMetric() {
        #expect(ShapeMetrics.erosion(functions: [], threshold: 10) == nil)
    }

    // MARK: - The threshold is a parameter, and §4.5 sweeps it

    @Test("The cyclomatic threshold decides which functions erode, and moving it moves the ratio")
    func thresholdChangesWhatErodes() {
        // Three equal-length functions straddling the sweep §4.5 asks for: 8, 10, 12.
        // Equal length means mass differs only by complexity, so the arithmetic stays checkable
        // by hand — the point is which functions are *selected*, not how they are weighted.
        let functions = [function(cc: 9, lines: 20),
                         function(cc: 11, lines: 20),
                         function(cc: 13, lines: 20)]

        guard let at8 = ShapeMetrics.erosion(functions: functions, threshold: 8),
              let at10 = ShapeMetrics.erosion(functions: functions, threshold: 10),
              let at12 = ShapeMetrics.erosion(functions: functions, threshold: 12) else {
            Issue.record("expected an erosion report at each threshold")
            return
        }

        // 8 catches all three, 10 catches two, 12 catches one.
        #expect(at8.functionsOverThreshold == 3)
        #expect(at10.functionsOverThreshold == 2)
        #expect(at12.functionsOverThreshold == 1)

        // And the headline moves with them, strictly. A threshold the metric ignored would
        // make these three equal, which is the failure this test exists to catch: §4.5's
        // sweep cannot measure sensitivity to a knob that does nothing.
        #expect(at8.erosion > at10.erosion)
        #expect(at10.erosion > at12.erosion)

        // At 8 every function is over, so the mass-weighted ratio is exactly one.
        #expect(abs(at8.erosion - 1.0) < 1e-9)
        // At 12 only the CC-13 function is over: mass 13√20 of (9 + 11 + 13)√20.
        #expect(abs(at12.erosion - 13.0 / 33.0) < 1e-9)
    }

    @Test("A report carries the threshold that produced it")
    func reportRecordsItsOwnThreshold() {
        // A sweep writes one snapshot per threshold. Without this the outputs are
        // indistinguishable after the fact, and a stability result cannot say what it varied.
        for threshold in [8, 10, 12] {
            guard let report = ShapeMetrics.erosion(
                functions: [function(cc: 11, lines: 20)], threshold: threshold) else {
                Issue.record("expected an erosion report at threshold \(threshold)")
                return
            }
            #expect(report.threshold == threshold)
        }
    }

    @Test("A package with no source lines has no verbosity, not zero verbosity")
    func noSourceMeansNoMetric() {
        #expect(ShapeMetrics.verbosity(regions: [], sloc: [:], config: ShapeConfig()) == nil)
        #expect(ShapeMetrics.verbosity(
            regions: [],
            sloc: [fileA: SLOCProfile(codeLines: [])],
            config: ShapeConfig()
        ) == nil)
    }

    @Test("A clean package has a verbosity of zero, which is not the same as none")
    func cleanPackageScoresZero() throws {
        let report = ShapeMetrics.verbosity(
            regions: [],
            sloc: [fileA: solidProfile(100)],
            config: ShapeConfig()
        )
        #expect(abs(try require(report).verbosity) < 1e-9)
    }

    // MARK: - 8, 9 & 10. Coverage is computed, and absence is never silent

    @Test("With a contributor missing, the headline is withheld rather than partial")
    func partialUnionIsWithheld() throws {
        let report = ShapeMetrics.compute(
            regions: [region("idiom.empty-count", 1...10)],
            sloc: [fileA: solidProfile(100)],
            functions: [function(cc: 3, lines: 10)],
            missingCheckers: ["duplication"]
        )
        // Asserted on the absence of the number: reporting a two-of-three union as if it were
        // the ratio is the failure this prevents.
        #expect(report.verbosity == nil)
        #expect(report.coverage.isComplete == false)
        #expect(report.coverage.summary.contains("duplication"))
        // Erosion does not depend on the union, so it survives — and says so by value.
        let erosion = try #require(report.erosion)
        #expect(erosion.functionCount == 1)
    }

    @Test("With every contributor present, the headline is reported")
    func completeCoverageYieldsAHeadline() throws {
        let report = ShapeMetrics.compute(
            regions: [region("idiom.empty-count", 1...10)],
            sloc: [fileA: solidProfile(100)],
            functions: [function(cc: 3, lines: 10)]
        )
        let verbosity = try #require(report.verbosity)
        #expect(abs(verbosity.verbosity - 0.10) < 1e-9)
        #expect(report.coverage.isComplete)
        #expect(report.coverage.summary.contains("every contributing checker ran"))
    }

    @Test("A rule reporting no region is named, not silently counted as one line")
    func rulesWithoutSpansAreNamed() throws {
        let diagnostics = [
            Diagnostic(severity: .note, message: "m", filePath: fileA, lineNumber: 3,
                       ruleId: "idiom.empty-count", endLine: 3),
            Diagnostic(severity: .note, message: "m", filePath: fileA, lineNumber: 7,
                       ruleId: "idiom.mystery"),
        ]
        let extracted = FlaggedRegion.extract(from: diagnostics)
        #expect(extracted.regions.count == 1)
        #expect(extracted.rulesWithoutSpan == ["idiom.mystery"])

        let report = ShapeMetrics.compute(
            regions: extracted.regions,
            sloc: [fileA: solidProfile(100)],
            functions: [function(cc: 3, lines: 10)],
            rulesWithoutSpan: Array(extracted.rulesWithoutSpan)
        )
        #expect(report.coverage.summary.contains("idiom.mystery"))
        // One line, not two: the spanless finding contributed nothing rather than 1.
        #expect(abs(try require(report.verbosity).verbosity - 0.01) < 1e-9)
    }

    @Test("The coverage note is computed from what ran, not written as a literal")
    func coverageNoteIsComputed() {
        let note = ShapeCoverage(missingCheckers: ["smells", "duplication"], rulesWithoutSpan: [])
        // Sorted, so the sentence does not depend on the order checkers happened to fail in.
        #expect(note.summary.contains("duplication, smells"))
    }

    // MARK: - SLOC profiling

    @Test("Comments and blank lines are not source lines")
    func slocExcludesCommentsAndBlanks() {
        let source = """
        // a leading comment
        let a = 1

        /* block
           comment */
        let b = 2
        """
        let profile = SLOCProfile.profile(source: source)
        #expect(profile.codeLines == [2, 6])
    }

    @Test("Every line of a multi-line string literal is source")
    func multiLineStringsCountThroughout() {
        let source = "let s = \"\"\"\nalpha\nbeta\n\"\"\"\n"
        let profile = SLOCProfile.profile(source: source)
        #expect(profile.codeLines.contains(2))
        #expect(profile.codeLines.contains(3))
    }
}
