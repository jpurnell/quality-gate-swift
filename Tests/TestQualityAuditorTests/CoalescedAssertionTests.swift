import Testing
import TestQualityAuditor
import QualityGateCore

/// `coalesced-assertion` — an assertion that fabricates a value for one that was missing.
///
/// The reference truth is BusinessMath's swept corpus: 211 sites removed, and every site
/// that remains was individually judged. A rule is correct when it flags what was removed
/// and stays quiet on what was kept. The "must not flag" fixtures below are therefore not
/// invented — each is a shape that exists, is correct, and would have been reported by a
/// rule that matched `??` and stopped there.
@Suite
struct CoalescedAssertionTests {

    private let auditor = TestQualityAuditor()
    private let ruleId = "coalesced-assertion"

    private func diagnostics(_ source: String) async throws -> [Diagnostic] {
        let result = try await auditor.auditSource(
            source, fileName: "SomeTests.swift", configuration: Configuration())
        return result.diagnostics.filter { $0.ruleId == ruleId }
    }

    // MARK: - Must flag

    @Test
    func flagsCoalescedZeroInsideAToleranceComparison() async throws {
        // `TimeSeriesAnalyticsTests.swift@2251c71a:111`, the site named in the proposal.
        let source = """
        import Testing

        @Test func movingAverage() {
            #expect(abs((ma[periods[0]] ?? 0) - 100.0) < 1e-6)
        }
        """

        let found = try await diagnostics(source)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 4)
    }

    @Test
    func flagsCoalescedSubscriptDefaultInABoundsComparison() async throws {
        let source = """
        import Testing

        @Test func allocations() {
            #expect(result.allocations["proj1"] ?? 0.0 > 0.5)
        }
        """

        let found = try await diagnostics(source)
        #expect(found.count == 1)
    }

    @Test
    func flagsCoalescedEmptyCollection() async throws {
        let source = """
        import Testing

        @Test func rows() {
            #expect((report?.rows ?? []).count == 3)
        }
        """

        let found = try await diagnostics(source)
        #expect(found.count == 1, "an empty collection is a fabricated value like any other")
    }

    @Test
    func flagsInsideRequire() async throws {
        let source = """
        import Testing

        @Test func lookup() throws {
            let score = try #require(scores["a"] ?? 0)
            #expect(score > 1)
        }
        """

        let found = try await diagnostics(source)
        #expect(found.count == 1, "#require fabricates a value just as #expect does")
    }

    @Test
    func flagsTrueFallbackOnTheWholeCondition() async throws {
        // The mirror image of the `?? false` carve-out below: `true` makes a missing value
        // *pass*, which is the entire defect this rule is named for.
        let source = """
        import Testing

        @Test func converged() {
            #expect(fit?.converged ?? true)
        }
        """

        let found = try await diagnostics(source)
        #expect(found.count == 1)
    }

    @Test
    func severityIsWarningUntilTheCorpusIsClear() async throws {
        // Promoted to `error` on 2026-09-16 and reverted the same day. The five repositories in
        // its proposal were clear; the corpus knows 75 that run this checker, and 19 of them
        // held 113 findings. Re-promotion is gated on a corpus query returning zero, not on a
        // hand sweep of a proposal's list — see the rule table in `TestQualityAuditor`.
        let source = """
        import Testing

        @Test func movingAverage() {
            #expect(abs((ma[periods[0]] ?? 0) - 100.0) < 1e-6)
        }
        """

        let found = try await diagnostics(source)
        #expect(found.first?.severity == .warning)
    }

    @Test
    func suggestedFixSaysRequireCannotBeInlined() async throws {
        // §16 of the proposal: `#expect(abs(try #require(x) - v) < t)` does not compile,
        // because the macro expands its condition into a non-throwing closure. Every person
        // who acts on this diagnostic rediscovers that the same way unless it says so.
        let source = """
        import Testing

        @Test func movingAverage() {
            #expect(abs((ma[periods[0]] ?? 0) - 100.0) < 1e-6)
        }
        """

        let fix = try await diagnostics(source).first?.suggestedFix ?? ""
        #expect(fix.contains("#require"), "the fix names the replacement")
        #expect(fix.contains("throws"), "and says the enclosing function must be marked throws")
    }

    // MARK: - Must not flag

    @Test
    func ignoresCoalescingInTheAssertionMessage() async throws {
        let source = """
        import Testing

        @Test func lookup() {
            #expect(found?.count == 1, "got \\(found ?? [])")
        }
        """

        let found = try await diagnostics(source)
        #expect(found.isEmpty, "a fallback in the failure message cannot change whether the test passes")
    }

    @Test
    func ignoresPoisonFallbackThatIsNotALiteral() async throws {
        // `.infinity` is chosen precisely because it cannot be a plausible value, so a
        // missing `rHat` makes the comparison fail rather than pass.
        let source = """
        import Testing

        @Test func convergence() {
            #expect((rHat ?? .infinity) < 1.1)
        }
        """

        let found = try await diagnostics(source)
        #expect(found.isEmpty, "a non-literal fallback is a poison value, not a default")
    }

    @Test
    func ignoresFalseFallbackOnTheWholeCondition() async throws {
        // The canonical Swift spelling of "non-nil and true". A missing value yields
        // `false`, which fails the assertion — loudly enough, and there is no shorter
        // correct way to write it.
        let source = """
        import Testing

        @Test func message() {
            #expect(scoreDiag?.message.contains("consistency score") ?? false)
        }
        """

        let found = try await diagnostics(source)
        #expect(found.isEmpty, "false in boolean position makes absence fail")
    }

    @Test
    func ignoresFalseFallbackInsideAConjunction() async throws {
        let source = """
        import Testing

        @Test func message() {
            #expect(diag.severity == .warning && (diag.message?.hasPrefix("Tolerance") ?? false))
        }
        """

        let found = try await diagnostics(source)
        #expect(found.isEmpty, "false still propagates to failure through an &&")
    }

    @Test
    func flagsFalseFallbackUnderANegation() async throws {
        // Negated, the same fallback flips sense: a missing value now *passes*.
        let source = """
        import Testing

        @Test func message() {
            #expect(!(diag.message?.hasPrefix("Tolerance") ?? false))
        }
        """

        let found = try await diagnostics(source)
        #expect(found.count == 1, "under a negation, false is a benign default again")
    }

    @Test
    func ignoresCoalescingInsideAPredicateClosure() async throws {
        // The distinction `unasserted-optional-unwrap` already draws: a value returned from
        // a closure answers the closure, not the test. Inside a search predicate, "missing
        // means does not match" is the correct reading, and it is how this repository's own
        // tests are written.
        let source = """
        import Testing

        @Test func reportsRule() {
            #expect(scan.diagnostics.contains { ($0.ruleId ?? "").contains("bounded-io") })
        }
        """

        let found = try await diagnostics(source)
        #expect(found.isEmpty, "the fallback answers the predicate, not the assertion")
    }

    @Test
    func ignoresCoalescingWithAComputedFallback() async throws {
        let source = """
        import Testing

        @Test func lookup() {
            #expect((scores["a"] ?? defaultScore()) == 3)
        }
        """

        let found = try await diagnostics(source)
        #expect(found.isEmpty, "only a literal fallback is fabricated here; anything computed is the test's own choice")
    }

    @Test
    func ignoresCoalescingInsideAStringLiteral() async throws {
        // This repository's own `IdiomAuditorTests` asserts on fixture source that contains
        // `??`. Source text inside a string literal is not an expression.
        let source = """
        import Testing

        @Test func redundantCoalescing() {
            #expect(findings("let y = maybe ?? 0", rule: "idiom.redundant-nil-coalescing").count == 0)
        }
        """

        let found = try await diagnostics(source)
        #expect(found.isEmpty)
    }

    @Test
    func ignoresCoalescingOutsideAnAssertion() async throws {
        let source = """
        import Testing

        @Test func lookup() {
            let score = scores["a"] ?? 0
            #expect(score >= 0)
        }
        """

        let found = try await diagnostics(source)
        #expect(found.isEmpty, "a fallback the test states as its own setup is visible; one buried in an assertion is not")
    }

    // MARK: - Suppression

    @Test
    func markerNamingTheRuleSuppressesItAndIsRecorded() async throws {
        let source = """
        import Testing

        @Test func sparseCounter() {
            // TEST-QUALITY: coalesced-assertion — the counter is sparse; absent and zero are the same fact
            #expect((counts["a"] ?? 0) >= 0)
        }
        """

        let result = try await auditor.auditSource(
            source, fileName: "SomeTests.swift", configuration: Configuration())
        #expect(result.diagnostics.filter { $0.ruleId == ruleId }.isEmpty)
        #expect(result.overrides.filter { $0.ruleId == ruleId }.count == 1, "the judgement is recorded, not merely absent")
    }

    @Test
    func blanketMarkerDoesNotSuppressIt() async throws {
        let source = """
        import Testing

        @Test func sparseCounter() {
            #expect((counts["a"] ?? 0) >= 0) // TEST-QUALITY: sparse counter
        }
        """

        let found = try await diagnostics(source)
        #expect(found.count == 1, "a marker that does not name this rule must not silence it")
    }

    // MARK: - Idempotence

    @Test
    func twoRunsReportTheSameDiagnostics() async throws {
        let source = """
        import Testing

        @Test func movingAverage() {
            #expect(abs((ma[periods[0]] ?? 0) - 100.0) < 1e-6)
            #expect((report?.rows ?? []).count == 3)
        }
        """

        let first = try await diagnostics(source)
        let second = try await diagnostics(source)
        #expect(first.count == 2)
        #expect(first.map(\.lineNumber) == second.map(\.lineNumber))
        #expect(first.map(\.message) == second.map(\.message))
    }
}
