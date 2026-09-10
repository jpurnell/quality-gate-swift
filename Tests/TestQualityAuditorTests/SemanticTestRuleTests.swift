import XCTest
import TestQualityAuditor
import QualityGateCore

/// Rules that look for *shapes* correlated with a vacuous test, rather than for a
/// malformed assertion.
///
/// Every rule here carries a negative fixture that looks like the flagged shape and is
/// correct. That is the test that matters: a rule which fires on correct code is disabled
/// within a week, and then it protects nothing.
final class SemanticTestRuleTests: XCTestCase {

    private let auditor = TestQualityAuditor()
    private let config = Configuration()

    /// A configuration with every opt-in semantic rule turned on.
    ///
    /// `tolerance-without-magnitude` and `assertion-on-constant` ship off by default
    /// because they arrive red on real corpora — see `TestQualityVisitor.optInRules`. The
    /// tests must enable them explicitly, which also keeps the default-off behaviour
    /// honest: `testOptInRulesAreSilentByDefault` asserts the other half.
    private var configWithOptInRules: Configuration {
        var enabled = Configuration()
        enabled.enabledCheckers = [
            "test-quality.tolerance-without-magnitude",
            "test-quality.assertion-on-constant",
            "test-quality.unvaried-parameter",
        ]
        return enabled
    }

    private func diagnostics(
        _ source: String,
        ruleId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [Diagnostic] {
        let result = try await auditor.auditSource(
            source, fileName: "SomeTests.swift", configuration: configWithOptInRules)
        return result.diagnostics.filter { $0.ruleId == ruleId }
    }

    func testOptInRulesAreSilentByDefault() async throws {
        let source = """
        import Testing

        @Test func placeholder() {
            #expect(true)
            #expect(abs(total - 1000.0) < 50.0)
        }
        """

        let result = try await auditor.auditSource(
            source, fileName: "SomeTests.swift", configuration: Configuration())
        let optIn = result.diagnostics.filter {
            $0.ruleId == "assertion-on-constant" || $0.ruleId == "tolerance-without-magnitude"
        }
        XCTAssertTrue(optIn.isEmpty, "these rules report only when a project asks for them")
    }

    // MARK: - unvaried-parameter (§3.3)

    func testFlagsSingleCallWithAllLiteralArgumentsAndOneAssertion() async throws {
        let source = """
        import Testing

        @Test func feasibility() {
            #expect(solve(weight: 500, height: 20).isFeasible)
        }
        """

        let found = try await diagnostics(source, ruleId: "unvaried-parameter")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.severity, .warning)
    }

    func testAllowsCallExercisedAtSeveralValues() async throws {
        let source = """
        import Testing

        @Test func feasibilityGrowsWithWeight() {
            let light = solve(weight: 100, height: 20)
            let heavy = solve(weight: 900, height: 20)
            #expect(light.margin > heavy.margin)
        }
        """

        let found = try await diagnostics(source, ruleId: "unvaried-parameter")
        XCTAssertTrue(found.isEmpty, "two call sites can distinguish an ignored parameter")
    }

    func testAllowsSingleCallWithSeveralAssertions() async throws {
        let source = """
        import Testing

        @Test func feasibility() {
            let result = solve(weight: 500, height: 20)
            #expect(result.isFeasible)
            #expect(result.margin > 0.0)
            #expect(result.iterations < 100)
        }
        """

        let found = try await diagnostics(source, ruleId: "unvaried-parameter")
        XCTAssertTrue(found.isEmpty)
    }

    func testAllowsSingleCallWithAComputedArgument() async throws {
        let source = """
        import Testing

        @Test func feasibility() {
            #expect(solve(weight: makeWeight(), height: 20).isFeasible)
        }
        """

        let found = try await diagnostics(source, ruleId: "unvaried-parameter")
        XCTAssertTrue(found.isEmpty, "a computed argument is not a fixed one")
    }

    // Three shapes the first draft of this rule flagged across BusinessMath. All correct.

    func testIgnoresTestWhoseOnlyCallBuildsAFixture() async throws {
        let source = """
        import Testing

        @Test func singleDMUThrows() throws {
            let dmu = DMU(name: "A", inputs: [1.0], outputs: [1.0])
            #expect(throws: DEAError.self) {
                _ = try solver.solve(dmus: [dmu])
            }
        }
        """

        let found = try await diagnostics(source, ruleId: "unvaried-parameter")
        XCTAssertTrue(
            found.isEmpty,
            "constructing a fixture is not calling the function under test")
    }

    func testIgnoresConformanceTest() async throws {
        let source = """
        import Testing

        @Test func dmuIsSendable() {
            let dmu = DMU(name: "A", inputs: [1.0], outputs: [1.0])
            let sendable: any Sendable = dmu
            #expect(sendable is DMU)
        }
        """

        let found = try await diagnostics(source, ruleId: "unvaried-parameter")
        XCTAssertTrue(found.isEmpty, "a conformance has no parameter to vary")
    }

    func testIgnoresThrowsExpectation() async throws {
        let source = """
        import Testing

        @Test func rejectsNegativeWeight() throws {
            #expect(throws: SolverError.self) {
                _ = try solve(weight: -1.0)
            }
        }
        """

        let found = try await diagnostics(source, ruleId: "unvaried-parameter")
        XCTAssertTrue(
            found.isEmpty,
            "asserting a refusal at one input is a complete statement")
    }

    // MARK: - Suppression is per rule, not blanket

    func testBlanketMarkerDoesNotSuppressANewRule() async throws {
        // BusinessMath carries 73 lines of `#expect(true) // TEST-QUALITY: <something>`,
        // written to satisfy `missing-assertion`. Every one is exactly what
        // `assertion-on-constant` exists to find. An unscoped marker would have let the
        // comment that excused one rule silently excuse the rule built to catch it.
        let source = """
        import Testing

        @Test func executesWithoutThrowing() throws {
            try interpolate(samples)
            #expect(true) // TEST-QUALITY: validates no-throw execution
        }
        """

        let found = try await diagnostics(source, ruleId: "assertion-on-constant")
        XCTAssertEqual(
            found.count, 1,
            "a marker that does not name this rule must not silence it")
    }

    func testMarkerNamingTheRuleSuppressesIt() async throws {
        let source = """
        import Testing

        @Test func executesWithoutThrowing() throws {
            try interpolate(samples)
            #expect(true) // TEST-QUALITY: assertion-on-constant — the assertion is that the call above did not throw
        }
        """

        let result = try await auditor.auditSource(
            source, fileName: "SomeTests.swift", configuration: configWithOptInRules)
        XCTAssertTrue(result.diagnostics.filter { $0.ruleId == "assertion-on-constant" }.isEmpty)
        XCTAssertEqual(
            result.overrides.filter { $0.ruleId == "assertion-on-constant" }.count, 1,
            "and the acknowledgement is recorded, not merely absent")
    }

    // MARK: - non-strict-improvement (§3.4)

    func testFlagsNonStrictComparisonInATestClaimingImprovement() async throws {
        let source = """
        import Testing

        @Test func refinementImprovesTheFit() {
            let refined = refine(start)
            #expect(refined.error <= start.error)
        }
        """

        let found = try await diagnostics(source, ruleId: "non-strict-improvement")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.severity, .warning)
    }

    func testAllowsBoundsCheckAgainstALiteral() async throws {
        // Five of the seven matches a grep produced on BusinessMath were this: a bounds
        // check in a test whose name merely contains a trigger word. A comparison against
        // a constant is not a claim that anything improved.
        let source = """
        import Testing

        @Test func improvedRateStaysInRange() {
            let rate = compute()
            #expect(rate >= 0.0)
            #expect(rate <= 1.0)
        }
        """

        let found = try await diagnostics(source, ruleId: "non-strict-improvement")
        XCTAssertTrue(found.isEmpty, "a bound is not an improvement claim")
    }

    func testAllowsCompoundBoundsCheck() async throws {
        // From the corpus. Splitting the flat sequence at the *first* comparison operator
        // made the right-hand side `0.0 && stats.gap <= 100.0` — not a literal, so the
        // literal exemption missed and a plain range assertion was reported.
        let source = """
        import Testing

        @Test func gapClosedImproves() {
            #expect(stats.percentageGapClosed >= 0.0 && stats.percentageGapClosed <= 100.0)
        }
        """

        let found = try await diagnostics(source, ruleId: "non-strict-improvement")
        XCTAssertTrue(found.isEmpty, "each conjunct is a bound against a literal")
    }

    func testFlagsImprovementClaimInsideACompound() async throws {
        let source = """
        import Testing

        @Test func refinementImprovesTheFit() {
            #expect(refined.error <= start.error && refined.iterations < 100)
        }
        """

        let found = try await diagnostics(source, ruleId: "non-strict-improvement")
        XCTAssertEqual(found.count, 1, "the conjuncts are read one at a time")
    }

    func testIgnoresNonStrictComparisonInATestNotClaimingImprovement() async throws {
        let source = """
        import Testing

        @Test func errorIsBounded() {
            #expect(fitted.error <= baseline.error)
        }
        """

        let found = try await diagnostics(source, ruleId: "non-strict-improvement")
        XCTAssertTrue(found.isEmpty)
    }

    func testStrictComparisonSatisfiesTheImprovementClaim() async throws {
        let source = """
        import Testing

        @Test func refinementImprovesTheFit() {
            #expect(refine(start).error < start.error)
        }
        """

        let found = try await diagnostics(source, ruleId: "non-strict-improvement")
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - tolerance-without-magnitude (§3.7)

    func testFlagsToleranceTooLooseForItsMagnitude() async throws {
        let source = """
        import Testing

        @Test func revenue() {
            #expect(abs(total - 1000.0) < 50.0)
        }
        """

        let found = try await diagnostics(source, ruleId: "tolerance-without-magnitude")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.severity, .warning)
    }

    func testAllowsTightToleranceForItsMagnitude() async throws {
        let source = """
        import Testing

        @Test func revenue() {
            #expect(abs(total - 1000.0) < 1e-6)
        }
        """

        let found = try await diagnostics(source, ruleId: "tolerance-without-magnitude")
        XCTAssertTrue(found.isEmpty)
    }

    func testIgnoresToleranceWithNoKnownMagnitude() async throws {
        // Both operands are computed, so there is no literal to take a ratio against.
        // Reporting here would be guessing.
        let source = """
        import Testing

        @Test func agreement() {
            #expect(abs(measured - expected) < 0.5)
        }
        """

        let found = try await diagnostics(source, ruleId: "tolerance-without-magnitude")
        XCTAssertTrue(found.isEmpty, "no magnitude in the expression means no ratio to judge")
    }

    // MARK: - assertion-on-constant (§3.6)

    func testFlagsAssertionBetweenLiterals() async throws {
        let source = """
        import Testing

        @Test func placeholder() {
            #expect(1.0 == 1.0)
        }
        """

        let found = try await diagnostics(source, ruleId: "assertion-on-constant")
        XCTAssertEqual(found.count, 1)
    }

    func testAllowsAssertionThatCallsIntoTheCode() async throws {
        let source = """
        import Testing

        @Test func mean() {
            #expect(average([1.0, 2.0, 3.0]) == 2.0)
        }
        """

        let found = try await diagnostics(source, ruleId: "assertion-on-constant")
        XCTAssertTrue(found.isEmpty)
    }

    func testAllowsAssertionOnAComputedValue() async throws {
        let source = """
        import Testing

        @Test func mean() {
            let result = average(samples)
            #expect(result == 2.0)
        }
        """

        let found = try await diagnostics(source, ruleId: "assertion-on-constant")
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - skipped-test-inventory (§3.2)

    func testInventoriesDisabledTestWithItsReason() async throws {
        let source = """
        import Testing

        @Test(.disabled("Metal initialization quirk in test environment"))
        func gpuDeterminism() {
            #expect(compute() == 4)
        }
        """

        let found = try await diagnostics(source, ruleId: "skipped-test-inventory")
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(
            found.first?.message.contains("Metal initialization quirk") ?? false,
            "the stated reason is the whole value of the inventory")
    }

    func testInventoryNeverGatesTheBuild() async throws {
        let source = """
        import Testing

        @Test(.disabled("Enable after adding validation"))
        func validates() {
            #expect(check() == true)
        }
        """

        let result = try await auditor.auditSource(
            source, fileName: "SomeTests.swift", configuration: config)
        let found = result.diagnostics.filter { $0.ruleId == "skipped-test-inventory" }
        XCTAssertEqual(found.first?.severity, .note)
        XCTAssertEqual(
            result.status, .passed,
            "a standing inventory reports; it does not block an unrelated commit")
    }

    func testInventoriesXCTSkip() async throws {
        let source = """
        import XCTest

        final class SlowTests: XCTestCase {
            func testExpensive() throws {
                throw XCTSkip("Takes 40 minutes on CI")
            }
        }
        """

        let found = try await diagnostics(source, ruleId: "skipped-test-inventory")
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first?.message.contains("40 minutes") ?? false)
    }

    func testInventoriesEnvironmentGatedEarlyReturn() async throws {
        let source = """
        import Testing

        @Test func expensiveSweep() {
            guard ProcessInfo.processInfo.environment["RUN_SLOW"] != nil else { return }
            #expect(sweep().count == 100)
        }
        """

        let found = try await diagnostics(source, ruleId: "skipped-test-inventory")
        XCTAssertEqual(found.count, 1)
    }

    func testEnvironmentGateIsNotAlsoAnUnassertedUnwrap() async throws {
        let source = """
        import Testing

        @Test func expensiveSweep() {
            guard let _ = ProcessInfo.processInfo.environment["RUN_SLOW"] else { return }
            #expect(sweep().count == 100)
        }
        """

        let unwrap = try await diagnostics(source, ruleId: "unasserted-optional-unwrap")
        let skip = try await diagnostics(source, ruleId: "skipped-test-inventory")
        XCTAssertTrue(unwrap.isEmpty, "an environment gate is a skip, not a defect")
        XCTAssertEqual(skip.count, 1, "and it is reported as exactly one of the two")
    }

    func testInventoriesConditionallyEnabledTest() async throws {
        // The shape BusinessMath actually uses for its nine environment-gated tests. It is
        // the *good* form — the skip is recorded by the framework rather than hidden behind
        // an early return — and it still belongs in the inventory, because a test that runs
        // only when someone exports RUN_BENCHMARKS does not run.
        let source = """
        import Testing

        @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_BENCHMARKS"] != nil,
                       "Skipped by default: set RUN_BENCHMARKS to enable"))
        func benchmarkSweep() {
            #expect(sweep().count == 100)
        }
        """

        let found = try await diagnostics(source, ruleId: "skipped-test-inventory")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.severity, .note)
        XCTAssertTrue(found.first?.message.contains("RUN_BENCHMARKS") ?? false)
    }

    func testInventoriesDisabledSuite() async throws {
        let source = """
        import Testing

        @Suite(.disabled("Rewrite pending"))
        struct RegressionSuite {
            @Test func first() { #expect(one() == 1) }
            @Test func second() { #expect(two() == 2) }
        }
        """

        let found = try await diagnostics(source, ruleId: "skipped-test-inventory")
        XCTAssertEqual(
            found.count, 1,
            "a disabled suite is reported once, at the suite — not once per test it hides")
        XCTAssertTrue(found.first?.message.contains("Rewrite pending") ?? false)
    }

    func testDoesNotInventoryAnOrdinaryTest() async throws {
        let source = """
        import Testing

        @Test("computes the mean")
        func mean() {
            #expect(abs(average([1.0, 2.0, 3.0]) - 2.0) < 1e-9)
        }
        """

        let found = try await diagnostics(source, ruleId: "skipped-test-inventory")
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - unasserted-optional-unwrap (§3.1)

    func testFlagsGuardLetWithBareReturn() async throws {
        let source = """
        import Testing

        @Test func gpuDeterminism() throws {
            guard let samples = try streamUniforms(count: 100, seed: 7) else { return }
            #expect(samples.count == 100)
        }
        """

        let found = try await diagnostics(source, ruleId: "unasserted-optional-unwrap")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.severity, .error)
        XCTAssertEqual(found.first?.lineNumber, 4)
    }

    func testAllowsGuardLetThatRecordsAnIssue() async throws {
        let source = """
        import Testing

        @Test func gpuDeterminism() throws {
            guard let samples = try streamUniforms(count: 100, seed: 7) else {
                Issue.record("GPU path unavailable")
                return
            }
            #expect(samples.count == 100)
        }
        """

        let found = try await diagnostics(source, ruleId: "unasserted-optional-unwrap")
        XCTAssertTrue(found.isEmpty, "a guard that reports its own failure is not silent")
    }

    func testAllowsGuardLetThatThrows() async throws {
        let source = """
        import Testing

        @Test func gpuDeterminism() throws {
            guard let samples = try streamUniforms(count: 100, seed: 7) else {
                throw TestError.noGPU
            }
            #expect(samples.count == 100)
        }
        """

        let found = try await diagnostics(source, ruleId: "unasserted-optional-unwrap")
        XCTAssertTrue(found.isEmpty)
    }

    func testIgnoresGuardLetOutsideATestFunction() async throws {
        let source = """
        import Testing

        func makeFixture() -> [Double] {
            guard let parsed = load() else { return [] }
            return parsed
        }
        """

        let found = try await diagnostics(source, ruleId: "unasserted-optional-unwrap")
        XCTAssertTrue(found.isEmpty, "a helper may legitimately fall back")
    }

    // The three fixtures below are not invented. Each is a shape the first draft of this
    // rule flagged across BusinessMath's 557 test files, and each is correct code. They are
    // kept verbatim in spirit because a rule at `error` severity earns that severity by
    // being quiet here.

    func testIgnoresGuardThatContinuesALoop() async throws {
        let source = """
        import Testing

        @Test func targetsDominate() {
            for score in scores {
                guard let dmu = cooperDMUs.first(where: { $0.name == score.name }) else {
                    continue
                }
                #expect(dmu.inputs.count == 3)
            }
        }
        """

        let found = try await diagnostics(source, ruleId: "unasserted-optional-unwrap")
        XCTAssertTrue(
            found.isEmpty,
            "continue skips one iteration; the test still runs its assertions")
    }

    func testIgnoresGuardInsideAPredicateClosure() async throws {
        let source = """
        import Testing

        @Test func variantsDiffer() {
            let differs = akima.contains { entry in
                guard let a = entry.schemes["original"], let b = entry.schemes["modified"] else { return false }
                return zip(a.values, b.values).contains { abs($0 - $1) > 1e-9 }
            }
            #expect(differs, "the two variants agree everywhere")
        }
        """

        let found = try await diagnostics(source, ruleId: "unasserted-optional-unwrap")
        XCTAssertTrue(
            found.isEmpty,
            "the guard returns from the predicate, not from the test")
    }

    func testIgnoresGuardInsideANestedHelperFunction() async throws {
        let source = """
        import Testing

        @Test func ratiosAreFinite() {
            func isFinite(_ x: Double?) -> Bool {
                guard let v = x else { return true }
                return v.isFinite && !v.isNaN
            }
            #expect(periods.allSatisfy { isFinite($0.value) })
        }
        """

        let found = try await diagnostics(source, ruleId: "unasserted-optional-unwrap")
        XCTAssertTrue(
            found.isEmpty,
            "the guard returns from the helper, not from the test")
    }

    func testIgnoresNonBindingGuard() async throws {
        let source = """
        import Testing

        @Test func metalOnly() {
            guard #available(macOS 14, *) else { return }
            #expect(compute() == 4)
        }
        """

        let found = try await diagnostics(source, ruleId: "unasserted-optional-unwrap")
        XCTAssertTrue(
            found.isEmpty,
            "platform gating is not an unasserted unwrap; §3.2 owns the skip inventory")
    }
}
