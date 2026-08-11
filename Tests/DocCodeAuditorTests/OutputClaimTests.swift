import Foundation
import Testing
@testable import DocCodeAuditor
import QualityGateCore

/// Rung 3: the article says what it prints, and it is telling the truth.
///
/// The convention was not designed here; it was read off a corpus of 95 claims in 13
/// articles. Three spellings are in use and they do not mean the same thing, which is why
/// two of them are parsed and the third is deliberately not:
///
/// - `// Result:` (85) is the *value of the binding above it*. 81 of those bindings are
///   never printed at all, which is why a stdout-capture implementation would verify a
///   sixth of this corpus and declare victory.
/// - `// Output:` (9) is a *transcript of stdout*, quoting the line the `print` above emits.
/// - `// →` (7) is not a claim. Two give an alternation of possible values; five are
///   editorial arrows in prose position. Recognising them would produce seven findings, all
///   false, on the first run.
@Suite("Output Claims")
struct OutputClaimTests {

    // MARK: - The three spellings

    @Test("Result and Output are claims; the arrow is not")
    func spellingsAreDistinguished() {
        let markdown = """
        ```swift
        let pv = 100.0
        // Result: 100
        print(pv)
        // Output: 100.0
        let forecastability = 1
        // → .strong / .moderate, low entropy
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.claims.count == 2)
        #expect(assembled.claims.map(\.kind) == [.value, .transcript])
        #expect(!assembled.claims.contains { $0.body.contains("entropy") })
    }

    @Test("A claim trailing on the code line itself is found")
    func trailingClaimIsFound() {
        // Three of the corpus's claims sit on the code line rather than under it. Handling
        // only the own-line position loses them silently, which is the one outcome a
        // coverage-conscious checker may not have.
        let markdown = """
        ```swift
        let seasonal = 1.25   // Result: ~1.25
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.claims.count == 1)
        #expect(assembled.claims.first?.anchor == .binding("seasonal"))
    }

    @Test("A claim inside an illustrative block is counted, not checked")
    func exemptClaimIsCounted() {
        let markdown = """
        <!-- docs:illustrative -->
        ```swift
        let sketch = pseudoCode()
        // Result: 42
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.claims.count == 1)
        #expect(assembled.claims.first?.isExempt == true)
    }

    // MARK: - Anchoring

    @Test("A claim under a file-scope binding anchors to that binding")
    func bindingAnchor() {
        let markdown = """
        ```swift
        let presentValue = 100.0
        // Result: 100,000
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.claims.first?.anchor == .binding("presentValue"))
    }

    @Test("A claim under a multi-line call anchors to the binding that opens it")
    func continuationAnchor() {
        // The dominant shape in the corpus: the line above the claim is a bare `)`, and the
        // binding is four lines further up. Anchoring to the nearest line rather than to the
        // nearest *statement* loses every one of these.
        let markdown = """
        ```swift
        let mortgage = payment(
            principal: 300_000,
            rate: 0.06,
            periods: 360
        )
        // Result: ~1,799
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.claims.first?.anchor == .binding("mortgage"))
    }

    @Test("A claim under a file-scope print anchors to stdout")
    func printAnchor() {
        let markdown = """
        ```swift
        print("Price: 1")
        // Output: Price: 1
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.claims.first?.anchor == .printStatement)
    }

    @Test("A claim on a nested print is reported unanchored, never guessed at")
    func nestedPrintIsUnanchored() {
        // The statement executes an unknown number of times, so "the next line of stdout" is
        // not well defined. Counted and named rather than silently skipped.
        let markdown = """
        ```swift
        for value in [1, 2, 3] {
            print(value)
            // Output: 1
        }
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.claims.first?.anchor == .unanchored)
    }

    // MARK: - Body parsing

    @Test("A trailing parenthetical is a gloss, not part of the claim")
    func parentheticalIsStripped() {
        // 33 of the corpus's own-line claims carry one, and none of them is on stdout.
        #expect(ClaimBody.parse("~166,792 (much less than 1000×360 = $360,000)")
            == .scalar(166792, tolerance: 2))
        #expect(ClaimBody.parse("2025 (FY2025 runs Oct 2024 - Sep 2025)")
            == .scalar(2025, tolerance: 0.5))
    }

    @Test("An em-dash gloss is stripped too")
    func emDashGlossIsStripped() {
        #expect(ClaimBody.parse("[0.1, 0.12, 0.115] — the same revenue restated in thousands")
            == .sequence([0.1, 0.12, 0.115], tolerances: [0.05, 0.005, 0.0005]))
    }

    @Test("A prose claim is not comparable, and says so")
    func proseIsNotComparable() {
        // 28 of 99. `// Result: Approaches but never exceeds 25,000` is a true and useful
        // statement that no comparator will ever evaluate. The count has to be visible.
        #expect(ClaimBody.parse("TimeSeries with 6 periods") == .prose)
        #expect(ClaimBody.parse("Allocate everything to risk-free asset") == .prose)
        #expect(ClaimBody.parse("Continues exponential growth pattern") == .prose)
    }

    @Test("A trailing unit phrase is a gloss, not prose")
    func unitPhraseIsStripped() {
        // `~1,799 per month` is a value claim with a unit on it. Rejecting it as prose would
        // discard a real number to avoid a parsing decision that cannot change the number.
        #expect(ClaimBody.parse("~1,799 per month") == .scalar(1799, tolerance: 2))
        #expect(ClaimBody.parse("3 periods") == .scalar(3, tolerance: 0.5))
    }

    @Test("A magnitude suffix is a multiplier, not a unit to be discarded")
    func magnitudeSuffixIsNotAUnit() {
        // Found by running the checker against a real catalogue. `$57.7M` was read as `57.7`
        // — the `M` looked like the start of a unit phrase — and the article was reported as
        // publishing 57.7 where the code produced 57,665,039. That is the worst kind of
        // false positive: it accuses correct documentation, in a checker whose entire
        // authority rests on its findings being true.
        //
        // The rule that fixes it is the one that should have been there: a letter *adjacent*
        // to the digits is a magnitude and must be one this parser knows; a unit phrase is
        // separated from the number by a space or a slash.
        #expect(ClaimBody.parse("$57.7M") == .scalar(57_700_000, tolerance: 50_000))
        #expect(ClaimBody.parse("100k") == .scalar(100_000, tolerance: 500))
        #expect(ClaimBody.parse("2.5B") == .scalar(2_500_000_000, tolerance: 50_000_000))
        // An adjacent letter run that is not a known magnitude is not a number this checker
        // may guess at.
        #expect(ClaimBody.parse("42xyz") == .prose)
        // A separated word is still a unit, and still safe to drop.
        #expect(ClaimBody.parse("3 periods") == .scalar(3, tolerance: 0.5))
        #expect(ClaimBody.parse("~1,799/month") == .scalar(1799, tolerance: 2))
    }

    @Test("A percentage is read in the units the documentation wrote it in")
    func percentIsScaled() {
        // The library returns a fraction and the article writes a percentage. Comparing the
        // two without converting fails every correct rate in the corpus.
        #expect(ClaimBody.parse("~24.9%") == .scalar(0.249, tolerance: 0.002))
        #expect(ClaimBody.parse("5.75%") == .scalar(0.0575, tolerance: 0.00005))
    }

    // MARK: - Tolerance

    @Test("100,000 accepts 99999.99999999999 — the whole comparison policy in one case")
    func roundedIntegerAcceptsItsOwnValue() {
        // String comparison fails on this *correct* number. IEEE equality fails on it. A
        // blanket 1e-6 fails on it. Half a unit in the last documented place passes it, and
        // this is the fixture a naive implementation gets wrong.
        let expected = ClaimBody.parse("100,000")
        #expect(expected == .scalar(100_000, tolerance: 0.5))
        #expect(ClaimComparison.matches(expected, [99999.99999999999]))
        #expect(!ClaimComparison.matches(expected, [100_001]))
    }

    @Test("A tilde widens the tolerance without disabling the check")
    func tildeWidensRatherThanDisables() {
        // 48 of 99 claims carry `~`. An author writing it is saying "about this", not "any
        // number" — so it buys two units in the last written place, not a free pass.
        let expected = ClaimBody.parse("~99,377")
        #expect(ClaimComparison.matches(expected, [99377.33254980117]))
        #expect(!ClaimComparison.matches(expected, [99_380]))
    }

    @Test("More documented digits mean a tighter check")
    func precisionIsSelfTightening() {
        #expect(ClaimComparison.matches(ClaimBody.parse("0.1447"), [0.14472]))
        #expect(!ClaimComparison.matches(ClaimBody.parse("0.1447"), [0.1448]))
    }

    @Test("A sequence is compared elementwise, and its length is part of the claim")
    func sequenceComparison() {
        let expected = ClaimBody.parse("[100, 120, 115]")
        #expect(ClaimComparison.matches(expected, [100, 120, 115]))
        // The real 1.2-TimeSeries defect: a claim wrong by a factor of 1,000, in an article
        // that passes rung 1, that nobody noticed.
        #expect(!ClaimComparison.matches(expected, [0.1, 0.12, 0.115]))
        #expect(!ClaimComparison.matches(expected, [100, 120]))
    }

    // MARK: - The three named comparisons

    @Test("The three claims that hide under == are named separately")
    func threeComparisonsAreDistinct() {
        // Reusing the vocabulary the test suite already uses, so an assertion says which
        // claim it is making rather than reaching for `==` by habit.
        #expect(!ClaimComparison.identical(-0.0, 0.0))
        #expect(ClaimComparison.exactlyEqual(-0.0, 0.0))
        #expect(ClaimComparison.identical(.nan, .nan))
        #expect(!ClaimComparison.exactlyEqual(.nan, .nan))
        #expect(ClaimComparison.approximatelyEqual(1.0, 1.4, tolerance: 0.5))
        #expect(!ClaimComparison.approximatelyEqual(1.0, 1.6, tolerance: 0.5))
    }

    // MARK: - Injection and line attribution

    @Test("An injected assertion reports the claim's line, and the next statement keeps its own")
    func injectionPreservesLineAttribution() throws {
        // The round trip most likely to be subtly wrong, and rung 3 is the first thing that
        // inserts lines into the assembled program. `articleLine` resolves by walking back to
        // the nearest marker, so an injection is safe *only* if it carries markers on both
        // sides of itself.
        //
        // Article lines: 1 fence, 2 `let a = 1`, 3 claim, 4 `let b = 2`, 5 fence
        let markdown = """
        ```swift
        let a = 1.0
        // Result: 1
        let b = 2.0
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: ["Foundation"])
        let injected = ClaimAssertionInjector.inject(into: assembled)

        // The *call*, not the helper's definition — the injected preamble declares five
        // overloads of the same name, and matching the first occurrence finds one of those.
        let assertionLine = injected.source.lines
            .firstIndex { $0.hasPrefix(ClaimAssertionInjector.assertionFunction + "(") }
            .map { $0 + 1 }
        #expect(injected.articleLine(forAssembledLine: try #require(assertionLine)) == 3)

        let afterLine = injected.source.lines.firstIndex(of: "let b = 2.0").map { $0 + 1 }
        #expect(injected.articleLine(forAssembledLine: try #require(afterLine)) == 4)
    }

    @Test("The instrumented program spells its sentinel rather than containing it")
    func sentinelIsEscapedInGeneratedSource() {
        // Interpolating the raw sentinel puts a literal 0x01 byte into `main.swift`, and
        // swiftc rejects the whole file with `unprintable ASCII character found in source
        // file`. Every instrumented article then fails to build, and the checker reports —
        // truthfully but uselessly — that no claim could be verified.
        let markdown = """
        ```swift
        let a = 1.0
        // Result: 1
        print("x")
        // Output: x
        ```
        """
        let injected = ClaimAssertionInjector.inject(
            into: ArticleAssembler.assemble(markdown, imports: ["Foundation"]))
        #expect(!injected.source.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" })
        #expect(injected.source.contains(#"\u{1}QGCLAIM"#))
    }

    @Test("Injection leaves an article with no claims exactly as it was")
    func noClaimsMeansNoChange() {
        let assembled = ArticleAssembler.assemble("```swift\nlet a = 1\n```", imports: ["Foundation"])
        #expect(ClaimAssertionInjector.inject(into: assembled).source == assembled.source)
    }

    // MARK: - Records

    @Test("A claim record survives the round trip through stderr")
    func recordRoundTrip() {
        let stderr = """
        some real error text
        \(ClaimRecord.sentinel)265\u{1}sequence\u{1}Array<Double>\u{1}0.1,0.12,0.115
        \(ClaimRecord.sentinel)27\u{1}scalar\u{1}Double\u{1}99999.99999999999
        more real text
        """
        let records = ClaimRecord.parse(stderr)
        #expect(records.count == 2)
        #expect(records[0].articleLine == 265)
        // Bit-identical, because the claim being made is that the record *round-tripped*.
        // A tolerance here would pass a channel that silently lost precision on the way
        // through stderr, which is the one thing this test exists to rule out.
        #expect(records[0].values.count == 3)
        #expect(zip(records[0].values, [0.1, 0.12, 0.115])
            .allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(records[1].shape == .scalar)
        // The article's own stderr survives; the instrumentation does not appear in it.
        let stripped = ClaimRecord.stripping(stderr)
        #expect(stripped.contains("some real error text"))
        #expect(stripped.contains("more real text"))
        #expect(!stripped.contains("QGCLAIM"))
    }
}

// MARK: - Fixtures

/// End-to-end: real markdown, real compilation, a real process, a real comparison.
@Suite("Doc Claims Fixtures", .serialized)
struct DocClaimsFixtureTests {

    private func check(_ markdown: String, named name: String = "Fixture.md") throws -> ClaimsVerdict {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-claims-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let article = directory.appendingPathComponent(name)
        try markdown.write(to: article, atomically: true, encoding: .utf8)

        var audit = DocCodeAuditOptions()
        audit.imports = ["Foundation"]
        audit.languageFlags = ["-swift-version", "6"]
        var options = DocRunOptions(audit: audit)
        options.verifiesDeterminism = true
        return try ClaimVerifier.verify(article: article, options: options)
    }

    // MARK: - Must fail

    @Test("A value claim wrong by a factor of 1,000 is caught")
    func timeSeriesDefectIsCaught() throws {
        // The real 1.2-TimeSeries defect, as a fixture. It passes rung 1 and rung 2.
        let verdict = try check("""
        ```swift
        let revenue = [100.0, 120.0, 115.0]
        let thousands = revenue.map { $0 / 1000.0 }
        // Result: [100, 120, 115]
        ```
        """)
        #expect(!verdict.passed)
        #expect(verdict.mismatches.count == 1)
        #expect(verdict.mismatches.first?.articleLine == 4)
    }

    @Test("A transcript claim off by 46 cents is caught")
    func bondPriceDefectIsCaught() throws {
        // The real 3.10-BondValuationGuide defect, in the transcript form easiest to check.
        let verdict = try check("""
        ```swift
        let price = 1043.76
        print("Price: $\\(String(format: "%.2f", price))")
        // Output: Price: $1,043.30 (trades at premium since coupon > yield)
        ```
        """)
        #expect(!verdict.passed)
        #expect(verdict.mismatches.count == 1)
    }

    @Test("A claim one unit past the documented precision is caught")
    func offByOneIsCaught() throws {
        let verdict = try check("""
        ```swift
        let pv = 99999.99999999999
        // Result: 100,001
        ```
        """)
        #expect(!verdict.passed)
    }

    // MARK: - Must pass

    @Test("100,000 passes against 99999.99999999999")
    func roundedValuePasses() throws {
        // The fixture that is the whole comparison policy.
        let verdict = try check("""
        ```swift
        let pv = 99999.99999999999
        // Result: 100,000
        ```
        """)
        #expect(verdict.passed, "\(verdict.mismatches)")
        #expect(verdict.checked == 1)
    }

    @Test("An approximate claim passes against its own value")
    func approximateValuePasses() throws {
        let verdict = try check("""
        ```swift
        let pv30 = 99377.33254980117
        // Result: ~99,377 (only 10% of future value!)
        ```
        """)
        #expect(verdict.passed, "\(verdict.mismatches)")
    }

    @Test("An ordered transcript match binds to the printed line, not to a later one")
    func transcriptConsumptionIsOrdered() throws {
        // 3.9-EquityValuationGuide prints `Intrinsic Value:` three times with three different
        // values and the claim binds to the first. A grep-for-the-substring implementation
        // passes on the wrong line.
        let verdict = try check("""
        ```swift
        print("Intrinsic Value: $50.00")
        // Output: Intrinsic Value: $50.00
        print("Intrinsic Value: $61.00")
        print("Intrinsic Value: $72.00")
        ```
        """)
        #expect(verdict.passed, "\(verdict.mismatches)")

        let wrong = try check("""
        ```swift
        print("Intrinsic Value: $45.00")
        // Output: Intrinsic Value: $50.00
        print("Intrinsic Value: $50.00")
        ```
        """, named: "Wrong.md")
        #expect(!wrong.passed)
    }

    // MARK: - Must report, not skip

    @Test("A prose claim is reported as not comparable, and counted")
    func proseIsReported() throws {
        let verdict = try check("""
        ```swift
        let series = [1.0, 2.0]
        // Result: TimeSeries with 6 periods
        ```
        """)
        #expect(verdict.notComparable.count == 1)
        #expect(verdict.checked == 0)
        #expect(verdict.found == 1)
    }

    @Test("A claim on a value that is not a number is reported, not passed")
    func opaqueValueIsReported() throws {
        let verdict = try check("""
        ```swift
        struct Portfolio { let name: String }
        let holding = Portfolio(name: "core")
        // Result: 100
        ```
        """)
        #expect(verdict.checked == 0)
        #expect(verdict.notComparable.count == 1)
    }

    @Test("Output that differs between runs blocks the whole article")
    func unreproducibleOutputBlocks() throws {
        // Wider than a single unstable value, and it has to be: a transcript claim binds to a
        // *position* in stdout, so when the stream itself moves there is nothing left to bind
        // against. This is the one non-determinism that is genuinely a property of the file.
        let verdict = try check("""
        ```swift
        let sample = Double.random(in: 0...1)
        // Result: 0.5
        print(sample)
        ```
        """)
        #expect(!verdict.passed)
        #expect(verdict.blocked?.contains("not reproducible") == true)
        #expect(verdict.checked == 0)
    }

    @Test("One unstable value does not blind the checker to the stable ones")
    func nondeterminismIsScopedToTheClaimThatHasIt() throws {
        // Found against a real catalogue: one value in a 37-claim article was unstable
        // between runs, and article-level blocking threw away the other 36 checks — a
        // catalogue-wide drop from 70 claims checked to 36. Non-determinism is a property of
        // the value, not of the file it is written in, and reporting it at file granularity
        // means one loose figure hides every other claim in the article.
        let verdict = try check("""
        ```swift
        let stable = 42.0
        // Result: 42
        let unstable = Double.random(in: 0...1)
        // Result: 0.5
        ```
        """)
        #expect(!verdict.passed)
        #expect(verdict.checked == 1)
        #expect(verdict.nondeterministic == [5])
        #expect(verdict.blocked == nil)
        #expect(verdict.mismatches.isEmpty)
    }

    @Test("An unseeded value that is never printed is still caught")
    func unprintedRandomnessIsCaught() throws {
        // The hole stdout-only determinism leaves, and it is the *dominant* shape in the
        // corpus: 81 of 99 claims describe a binding that is never printed. Both runs produce
        // byte-identical output — none — so a check on stdout alone certifies the article as
        // deterministic and then compares a documented figure against a random number.
        let verdict = try check("""
        ```swift
        let sample = Double.random(in: 0...1)
        // Result: 0.5
        ```
        """)
        #expect(!verdict.passed)
        #expect(verdict.nondeterministic == [3])
        #expect(verdict.checked == 0)
    }

    // MARK: - Negative control

    @Test("Known-true and known-false claims produce different verdicts")
    func negativeControl() throws {
        let good = try check("```swift\nlet a = 42.0\n// Result: 42\n```", named: "Good.md")
        let bad = try check("```swift\nlet a = 42.0\n// Result: 43\n```", named: "Bad.md")
        #expect(good.passed)
        #expect(good.checked == 1)
        #expect(!bad.passed)
        #expect(bad.checked == 1)
    }
}
