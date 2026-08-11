import Foundation
import QualityGateCore

/// What checking one article's documented values established.
public struct ClaimsVerdict: Sendable {

    /// A documented figure the program does not produce.
    public struct Mismatch: Sendable, Equatable {

        /// The article line the claim is written on.
        public let articleLine: Int

        /// The claim as the documentation writes it, with the comparison it implies.
        public let documented: String

        /// What the program actually produced.
        public let measured: String
    }

    /// Path of the article checked.
    public let articlePath: String

    /// Claims the article makes, including the ones nothing can be done with.
    public let found: Int

    /// Claims actually compared against a measurement.
    public let checked: Int

    /// Claims that were compared and did not hold.
    public let mismatches: [Mismatch]

    /// Article lines of claims whose anchor this checker cannot bind to.
    public let unanchored: [Int]

    /// Article lines of claims whose body is not a value, or whose value is not a number.
    public let notComparable: [Int]

    /// Article lines of claims inside `<!-- docs:illustrative -->` blocks.
    public let exempt: [Int]

    /// Article lines of claims whose measured value was not reproduced on a second run.
    ///
    /// Scoped to the claim rather than to the article, and that is deliberate. Blocking a
    /// whole file because one figure is unstable cost 34 of one article's 37 checks — and
    /// non-determinism is a property of the value, not of the file it happens to be written
    /// in. One loose figure must not hide every other claim around it.
    public let nondeterministic: [Int]

    /// Why nothing in this article could be verified, when that is the case.
    ///
    /// A build failure, a crash, or — the one that matters — output that differs between two
    /// runs. An unseeded example has no pinned output, so a checker that quietly passed it
    /// would certify the opposite of what it measured.
    public let blocked: String?

    /// Whether every comparable claim held, and the article could be measured at all.
    public var passed: Bool {
        mismatches.isEmpty && blocked == nil && nondeterministic.isEmpty
    }

    /// Creates a verdict.
    public init(
        articlePath: String, found: Int, checked: Int, mismatches: [Mismatch],
        unanchored: [Int], notComparable: [Int], exempt: [Int],
        nondeterministic: [Int] = [], blocked: String?
    ) {
        self.articlePath = articlePath
        self.found = found
        self.checked = checked
        self.mismatches = mismatches
        self.unanchored = unanchored
        self.notComparable = notComparable
        self.exempt = exempt
        self.nondeterministic = nondeterministic
        self.blocked = blocked
    }
}

/// Instruments, runs and compares one article's documented values.
public enum ClaimVerifier {

    /// Checks every claim in one article.
    ///
    /// - Parameters:
    ///   - article: The `.md` file.
    ///   - options: The run options — the same flags rungs 1 and 2 use.
    /// - Returns: The verdict, whose counts always distinguish claims *found* from claims
    ///   *checked*. The gap is the honest part of the report: 28 of 99 claims in the measured
    ///   corpus are prose, and a checker that reported only its successes would look like it
    ///   covered a third more of the documentation than it does.
    /// - Throws: If the article cannot be read or the work directory cannot be created.
    public static func verify(article: URL, options: DocRunOptions) throws -> ClaimsVerdict {
        let text = try String(contentsOf: article, encoding: .utf8)
        let assembled = ArticleAssembler.assemble(text, imports: options.audit.imports)
        let claims = assembled.claims

        let exempt = claims.filter(\.isExempt).map(\.articleLine)
        let live = claims.filter { !$0.isExempt }

        var unanchored: [Int] = []
        var comparable: [OutputClaim] = []
        var notComparable: [Int] = []
        var nondeterministic: [Int] = []

        for claim in live {
            switch (claim.kind, claim.anchor) {
            case (.value, .binding), (.transcript, .printStatement):
                comparable.append(claim)
            default:
                unanchored.append(claim.articleLine)
            }
        }

        func verdict(checked: Int, mismatches: [ClaimsVerdict.Mismatch], blocked: String?) -> ClaimsVerdict {
            ClaimsVerdict(
                articlePath: article.path, found: claims.count, checked: checked,
                mismatches: mismatches, unanchored: unanchored.sorted(),
                notComparable: notComparable.sorted(), exempt: exempt.sorted(),
                nondeterministic: nondeterministic.sorted(), blocked: blocked)
        }

        guard !comparable.isEmpty else {
            return verdict(checked: 0, mismatches: [], blocked: nil)
        }

        let instrumented = ClaimAssertionInjector.inject(into: assembled)
        let outcome = try ArticleRunner.run(
            assembled: instrumented, articlePath: article.path, options: options)

        switch outcome.verdict.outcome.termination {
        case .exited(0):
            break
        case .buildFailed(let reason):
            return verdict(checked: 0, mismatches: [], blocked: "the instrumented article does not build: \(reason)")
        default:
            return verdict(
                checked: 0, mismatches: [],
                blocked: "the article \(outcome.verdict.outcome.termination.summary)")
        }

        // Output that differs between runs blocks the whole article, because the stdout
        // markers a transcript claim binds to are themselves positions in that output — there
        // is nothing left to bind against. A differing *value* is narrower and is handled per
        // claim below.
        if let determinism = outcome.verdict.determinism, determinism.differingLines > 0 {
            return verdict(
                checked: 0, mismatches: [],
                blocked: """
                    the article's output is not reproducible — \(determinism.differingLines) of \
                    \(determinism.totalLines) stdout lines differ between two runs
                    """)
        }

        let records = Dictionary(
            outcome.records.map { ($0.articleLine, $0) }, uniquingKeysWith: { first, _ in first })
        let secondRecords = Dictionary(
            outcome.secondRecords.map { ($0.articleLine, $0) }, uniquingKeysWith: { first, _ in first })
        let (stdout, marks) = ClaimAssertionInjector.readMarks(outcome.verdict.outcome.standardOutput)

        var checked = 0
        var mismatches: [ClaimsVerdict.Mismatch] = []

        for claim in comparable {
            switch claim.kind {
            case .value:
                let expected = ClaimBody.parse(claim.body)
                guard expected != .prose else {
                    notComparable.append(claim.articleLine)
                    continue
                }
                guard let record = records[claim.articleLine], record.shape != .opaque else {
                    // The binding is real and the claim is a number, but the value is not
                    // reducible to one — a `TimeSeries`, a struct, an enum. Reported, because
                    // the alternative is a claim that silently stops being checked.
                    notComparable.append(claim.articleLine)
                    continue
                }
                // A value the program does not reproduce is not a value anyone can be held
                // to, and comparing it would report whichever of the two runs happened to be
                // first. Named, not quietly dropped and not counted as checked.
                guard let again = secondRecords[claim.articleLine],
                      again.values.count == record.values.count,
                      zip(record.values, again.values).allSatisfy(ClaimComparison.identical)
                else {
                    nondeterministic.append(claim.articleLine)
                    continue
                }
                checked += 1
                guard !ClaimComparison.matches(expected, record.values) else { continue }
                mismatches.append(
                    ClaimsVerdict.Mismatch(
                        articleLine: claim.articleLine,
                        documented: ClaimComparison.describe(expected),
                        measured: record.values.count == 1
                            ? "\(record.values[0])"
                            : "[" + record.values.map { "\($0)" }.joined(separator: ", ") + "]"))

            case .transcript:
                let expected = expectedTranscript(claim)
                guard !expected.isEmpty else {
                    notComparable.append(claim.articleLine)
                    continue
                }
                guard let index = marks[claim.articleLine], index < stdout.count else {
                    notComparable.append(claim.articleLine)
                    continue
                }
                checked += 1
                let actual = Array(stdout[index..<min(index + expected.count, stdout.count)])
                guard actual != expected else { continue }
                mismatches.append(
                    ClaimsVerdict.Mismatch(
                        articleLine: claim.articleLine,
                        documented: expected.joined(separator: " ⏎ "),
                        measured: actual.joined(separator: " ⏎ ")))
            }
        }

        return verdict(checked: checked, mismatches: mismatches, blocked: nil)
    }

    /// The stdout lines a transcript claim promises.
    ///
    /// The trailing parenthetical goes, because it is a gloss and is not on stdout:
    /// `Price: $1,043.30 (trades at premium since coupon > yield)` promises exactly
    /// `Price: $1,043.30`.
    static func expectedTranscript(_ claim: OutputClaim) -> [String] {
        let body = ClaimBody.strippingGloss(claim.body)
        guard !body.isEmpty else { return [] }
        return [body]
    }
}
