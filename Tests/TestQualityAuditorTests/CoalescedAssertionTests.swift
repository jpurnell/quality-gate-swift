import XCTest
import TestQualityAuditor
import QualityGateCore

/// `coalesced-assertion` — an assertion that fabricates a value for one that was missing.
///
/// The reference truth is BusinessMath's swept corpus: 211 sites removed, and every site
/// that remains was individually judged. A rule is correct when it flags what was removed
/// and stays quiet on what was kept. The "must not flag" fixtures below are therefore not
/// invented — each is a shape that exists, is correct, and would have been reported by a
/// rule that matched `??` and stopped there.
final class CoalescedAssertionTests: XCTestCase {

    private let auditor = TestQualityAuditor()
    private let ruleId = "coalesced-assertion"

    private func diagnostics(_ source: String) async throws -> [Diagnostic] {
        let result = try await auditor.auditSource(
            source, fileName: "SomeTests.swift", configuration: Configuration())
        return result.diagnostics.filter { $0.ruleId == ruleId }
    }

    // MARK: - Must flag

    func testFlagsCoalescedZeroInsideAToleranceComparison() async throws {
        // `TimeSeriesAnalyticsTests.swift@2251c71a:111`, the site named in the proposal.
        let source = """
        import Testing

        @Test func movingAverage() {
            #expect(abs((ma[periods[0]] ?? 0) - 100.0) < 1e-6)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lineNumber, 4)
    }

    func testFlagsCoalescedSubscriptDefaultInABoundsComparison() async throws {
        let source = """
        import Testing

        @Test func allocations() {
            #expect(result.allocations["proj1"] ?? 0.0 > 0.5)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1)
    }

    func testFlagsCoalescedEmptyCollection() async throws {
        let source = """
        import Testing

        @Test func rows() {
            #expect((report?.rows ?? []).count == 3)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1, "an empty collection is a fabricated value like any other")
    }

    func testFlagsInsideRequire() async throws {
        let source = """
        import Testing

        @Test func lookup() throws {
            let score = try #require(scores["a"] ?? 0)
            #expect(score > 1)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1, "#require fabricates a value just as #expect does")
    }

    func testFlagsTrueFallbackOnTheWholeCondition() async throws {
        // The mirror image of the `?? false` carve-out below: `true` makes a missing value
        // *pass*, which is the entire defect this rule is named for.
        let source = """
        import Testing

        @Test func converged() {
            #expect(fit?.converged ?? true)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1)
    }

    func testSeverityIsErrorAfterItsWarningRelease() async throws {
        // Shipped at `warning` on 2026-09-14 so five repositories could see their own
        // populations before anything blocked — 54 findings between them. Two working days
        // later the population was zero, every site repaired rather than suppressed, so the
        // condition ADR-001 sets for promotion was met.
        let source = """
        import Testing

        @Test func movingAverage() {
            #expect(abs((ma[periods[0]] ?? 0) - 100.0) < 1e-6)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.first?.severity, .error)
    }

    func testSuggestedFixSaysRequireCannotBeInlined() async throws {
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
        XCTAssertTrue(fix.contains("#require"), "the fix names the replacement")
        XCTAssertTrue(
            fix.contains("throws"),
            "and says the enclosing function must be marked throws")
    }

    // MARK: - Must not flag

    func testIgnoresCoalescingInTheAssertionMessage() async throws {
        let source = """
        import Testing

        @Test func lookup() {
            #expect(found?.count == 1, "got \\(found ?? [])")
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(
            found.isEmpty,
            "a fallback in the failure message cannot change whether the test passes")
    }

    func testIgnoresPoisonFallbackThatIsNotALiteral() async throws {
        // `.infinity` is chosen precisely because it cannot be a plausible value, so a
        // missing `rHat` makes the comparison fail rather than pass.
        let source = """
        import Testing

        @Test func convergence() {
            #expect((rHat ?? .infinity) < 1.1)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(found.isEmpty, "a non-literal fallback is a poison value, not a default")
    }

    func testIgnoresFalseFallbackOnTheWholeCondition() async throws {
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
        XCTAssertTrue(found.isEmpty, "false in boolean position makes absence fail")
    }

    func testIgnoresFalseFallbackInsideAConjunction() async throws {
        let source = """
        import Testing

        @Test func message() {
            #expect(diag.severity == .warning && (diag.message?.hasPrefix("Tolerance") ?? false))
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(
            found.isEmpty,
            "false still propagates to failure through an &&")
    }

    func testFlagsFalseFallbackUnderANegation() async throws {
        // Negated, the same fallback flips sense: a missing value now *passes*.
        let source = """
        import Testing

        @Test func message() {
            #expect(!(diag.message?.hasPrefix("Tolerance") ?? false))
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(found.count, 1, "under a negation, false is a benign default again")
    }

    func testIgnoresCoalescingInsideAPredicateClosure() async throws {
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
        XCTAssertTrue(
            found.isEmpty,
            "the fallback answers the predicate, not the assertion")
    }

    func testIgnoresCoalescingWithAComputedFallback() async throws {
        let source = """
        import Testing

        @Test func lookup() {
            #expect((scores["a"] ?? defaultScore()) == 3)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(
            found.isEmpty,
            "only a literal fallback is fabricated here; anything computed is the test's own choice")
    }

    func testIgnoresCoalescingInsideAStringLiteral() async throws {
        // This repository's own `IdiomAuditorTests` asserts on fixture source that contains
        // `??`. Source text inside a string literal is not an expression.
        let source = """
        import Testing

        @Test func redundantCoalescing() {
            #expect(findings("let y = maybe ?? 0", rule: "idiom.redundant-nil-coalescing").count == 0)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(found.isEmpty)
    }

    func testIgnoresCoalescingOutsideAnAssertion() async throws {
        let source = """
        import Testing

        @Test func lookup() {
            let score = scores["a"] ?? 0
            #expect(score >= 0)
        }
        """

        let found = try await diagnostics(source)
        XCTAssertTrue(
            found.isEmpty,
            "a fallback the test states as its own setup is visible; one buried in an assertion is not")
    }

    // MARK: - Suppression

    func testMarkerNamingTheRuleSuppressesItAndIsRecorded() async throws {
        let source = """
        import Testing

        @Test func sparseCounter() {
            // TEST-QUALITY: coalesced-assertion — the counter is sparse; absent and zero are the same fact
            #expect((counts["a"] ?? 0) >= 0)
        }
        """

        let result = try await auditor.auditSource(
            source, fileName: "SomeTests.swift", configuration: Configuration())
        XCTAssertTrue(result.diagnostics.filter { $0.ruleId == ruleId }.isEmpty)
        XCTAssertEqual(
            result.overrides.filter { $0.ruleId == ruleId }.count, 1,
            "the judgement is recorded, not merely absent")
    }

    func testBlanketMarkerDoesNotSuppressIt() async throws {
        let source = """
        import Testing

        @Test func sparseCounter() {
            #expect((counts["a"] ?? 0) >= 0) // TEST-QUALITY: sparse counter
        }
        """

        let found = try await diagnostics(source)
        XCTAssertEqual(
            found.count, 1,
            "a marker that does not name this rule must not silence it")
    }

    // MARK: - Idempotence

    func testTwoRunsReportTheSameDiagnostics() async throws {
        let source = """
        import Testing

        @Test func movingAverage() {
            #expect(abs((ma[periods[0]] ?? 0) - 100.0) < 1e-6)
            #expect((report?.rows ?? []).count == 3)
        }
        """

        let first = try await diagnostics(source)
        let second = try await diagnostics(source)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.map(\.lineNumber), second.map(\.lineNumber))
        XCTAssertEqual(first.map(\.message), second.map(\.message))
    }
}
