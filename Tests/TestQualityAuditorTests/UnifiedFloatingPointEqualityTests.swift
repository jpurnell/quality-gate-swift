import XCTest
import FloatingPointSafetyAuditor
import QualityGateCore
import TestQualityAuditor

/// One rule, one implementation, one marker.
///
/// `fp-equality` (FloatingPointSafetyAuditor) and `exact-double-equality`
/// (TestQualityAuditor) are the same rule reported by two checkers at two
/// severities. These tests pin the shared behaviour: identical detection,
/// identical suppression, and a diagnostic that presents the three claims
/// `==` can be making rather than asserting one.
final class UnifiedFloatingPointEqualityTests: XCTestCase {

    private let fpSafety = FloatingPointSafetyAuditor()
    private let testQuality = TestQualityAuditor()
    private let config = Configuration()

    /// A path that neither checker treats as a test file, so both actually
    /// analyse it. (In production `fp-safety` walks `Sources/` and
    /// `test-quality` walks `Tests/`; the shared rule must behave the same
    /// in both.)
    private let fixturePath = "Fixture.swift"

    private func fpEquality(_ source: String) async throws -> [Diagnostic] {
        let result = try await fpSafety.auditSource(source, fileName: fixturePath, configuration: config)
        return result.diagnostics.filter { $0.ruleId == "fp-equality" }
    }

    private func exactEquality(_ source: String) async throws -> [Diagnostic] {
        let result = try await testQuality.auditSource(source, fileName: fixturePath, configuration: config)
        return result.diagnostics.filter { $0.ruleId == "exact-double-equality" }
    }

    private func exactEqualityOverrides(_ source: String) async throws -> [DiagnosticOverride] {
        let result = try await testQuality.auditSource(source, fileName: fixturePath, configuration: config)
        return result.overrides.filter { $0.ruleId == "exact-double-equality" }
    }

    // MARK: - Must fail: a many-digit literal

    func testManyDigitLiteralIsFlaggedInAssertion() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            #expect(result == 0.3989422804014327)
        }
        """

        let tq = try await exactEquality(source)
        let fp = try await fpEquality(source)
        XCTAssertEqual(tq.count, 1)
        XCTAssertEqual(fp.count, 1)
    }

    func testManyDigitLiteralIsFlaggedOutsideAnAssertion() async throws {
        let source = """
        func classify() -> Bool {
            let result = compute()
            return result == 0.3989422804014327
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        // fp-safety owns non-assertion sites; test-quality deliberately does not.
        XCTAssertEqual(fp.count, 1)
        XCTAssertEqual(tq.count, 0)
    }

    // MARK: - Must fail: two computed Doubles, no literal anywhere

    /// The coverage hole in `TestQualityAuditor`'s private copy: it required a
    /// `FloatLiteralExprSyntax` on one side, so a comparison of two computed
    /// `Double`s was invisible to it.
    func testTwoComputedDoublesWithNoLiteralAreFlaggedInAssertion() async throws {
        let source = """
        import Testing

        @Test func testAgreement() {
            let expected: Double = referenceImplementation()
            let actual: Double = fastPath()
            #expect(actual == expected)
        }
        """

        let tq = try await exactEquality(source)
        let fp = try await fpEquality(source)
        XCTAssertEqual(
            tq.count, 1,
            "A literal-free comparison of two computed Doubles must be caught"
        )
        XCTAssertEqual(fp.count, 1)
    }

    func testTwoComputedDoublesWithNoLiteralAreFlaggedOutsideAnAssertion() async throws {
        let source = """
        func agrees() -> Bool {
            let expected: Double = referenceImplementation()
            let actual: Double = fastPath()
            return actual == expected
        }
        """

        let fp = try await fpEquality(source)
        XCTAssertEqual(fp.count, 1)
    }

    // MARK: - Must pass: the three unambiguous forms

    func testToleranceComparisonIsNotFlagged() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let actual: Double = fastPath()
            let expected: Double = referenceImplementation()
            #expect(abs(actual - expected) < 1e-9)
        }
        """

        let tq = try await exactEquality(source)
        let fp = try await fpEquality(source)
        XCTAssertEqual(tq.count, 0)
        XCTAssertEqual(fp.count, 0)
    }

    func testBitPatternComparisonIsNotFlagged() async throws {
        let source = """
        import Testing

        @Test func testReproducibility() {
            let actual: Double = fastPath()
            let expected: Double = referenceImplementation()
            #expect(actual.bitPattern == expected.bitPattern)
        }
        """

        let tq = try await exactEquality(source)
        let fp = try await fpEquality(source)
        XCTAssertEqual(
            tq.count, 0,
            "bitPattern comparison is the unambiguous bit-identity form; do not flag it"
        )
        XCTAssertEqual(fp.count, 0)
    }

    func testNamedIEEEEqualityIsNotFlagged() async throws {
        let source = """
        import Testing

        @Test func testIEEEEquality() {
            let actual: Double = fastPath()
            let expected: Double = referenceImplementation()
            #expect(actual.isEqual(to: expected))
        }
        """

        let tq = try await exactEquality(source)
        let fp = try await fpEquality(source)
        XCTAssertEqual(tq.count, 0)
        XCTAssertEqual(fp.count, 0)
    }

    func testIntegerComparisonInvolvingADoubleTypedVariableIsNotFlagged() async throws {
        let source = """
        import Testing

        @Test func testBucket() {
            let ratio: Double = fastPath()
            #expect(Int(ratio * 4) == 2)
        }
        """

        let tq = try await exactEquality(source)
        let fp = try await fpEquality(source)
        XCTAssertEqual(tq.count, 0)
        XCTAssertEqual(fp.count, 0)
    }

    /// `sqrt(-2 * log(1))` is `-0.0`; `==` against `0.0` is the correct
    /// comparison there and a bit-pattern check would fail. Both checkers
    /// exempt the zero sentinel.
    func testComparisonAgainstZeroSentinelIsNotFlagged() async throws {
        let source = """
        import Testing

        @Test func testDegenerateBoxMuller() {
            let z1: Double = boxMullerFirst()
            let z2: Double = boxMullerSecond()
            #expect(z1 == 0.0 && z2 == 0.0)
        }
        """

        let tq = try await exactEquality(source)
        let fp = try await fpEquality(source)
        XCTAssertEqual(tq.count, 0)
        XCTAssertEqual(fp.count, 0)
    }

    // MARK: - Regression: one marker, honoured by both checkers

    /// The bug this change fixes. A developer reads the failing diagnostic,
    /// applies the marker it names, re-runs, and the *other* checker still
    /// fails on the same line. Both checkers must honour `// fp-safety:disable`.
    func testCanonicalMarkerSuppressesInBothCheckers() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            #expect(result == 0.3989422804014327) // fp-safety:disable — lookup table entry, exact by construction
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        let overrides = try await exactEqualityOverrides(source)

        XCTAssertEqual(fp.count, 0, "fp-safety must honour its own marker")
        XCTAssertEqual(tq.count, 0, "test-quality must honour the same marker — this is the defect")
        XCTAssertEqual(
            overrides.count, 1,
            "A suppressed finding must still be recorded as an override, not vanish"
        )
    }

    func testCanonicalMarkerOnTheCommentLineAboveSuppressesInBothCheckers() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            // fp-safety:disable — lookup table entry, exact by construction
            #expect(result == 0.3989422804014327)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 0)
        XCTAssertEqual(tq.count, 0)
    }

    /// The legacy marker must keep working or every existing suppression in
    /// consumer projects breaks at once.
    func testLegacyTestQualityMarkerStillSuppresses() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            #expect(result == 0.3989422804014327) // TEST-QUALITY: lookup table entry, exact by construction
        }
        """

        let tq = try await exactEquality(source)
        let overrides = try await exactEqualityOverrides(source)
        let fp = try await fpEquality(source)

        XCTAssertEqual(tq.count, 0)
        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(
            fp.count, 0,
            "The two markers are one marker set; neither checker may ignore the other's"
        )
    }

    /// An inline marker must not leak onto the following line. 300 sites in
    /// BusinessMath carry a trailing `// fp-safety:disable`; if "the line
    /// above" matched those, every one of them would silently suppress its
    /// neighbour.
    func testInlineMarkerDoesNotSuppressTheFollowingLine() async throws {
        let source = """
        func classify() -> Bool {
            let a: Double = fastPath()
            let b: Double = referenceImplementation()
            let first = a == b // fp-safety:disable — sentinel identity
            let second = a == b
            return first && second
        }
        """

        let fp = try await fpEquality(source)
        XCTAssertEqual(fp.count, 1, "Only the marked line is suppressed")
    }

    // MARK: - The diagnostic names all three claims

    func testDiagnosticPresentsTheThreeClaimsRatherThanAssertingOne() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            #expect(result == 0.3989422804014327)
        }
        """

        let tqDiags = try await exactEquality(source)
        let fpDiags = try await fpEquality(source)
        let tqDiag = try XCTUnwrap(tqDiags.first)
        let fpDiag = try XCTUnwrap(fpDiags.first)

        for diagnostic in [tqDiag, fpDiag] {
            let text = diagnostic.message + " " + (diagnostic.suggestedFix ?? "")
            XCTAssertTrue(text.contains("abs(a - b) < epsilon"), "names the tolerance form")
            XCTAssertTrue(text.contains("a.isEqual(to: b)"), "names the IEEE-equality form")
            XCTAssertTrue(text.contains("a.bitPattern == b.bitPattern"), "names the bit-identity form")
            XCTAssertFalse(
                diagnostic.message.contains("Use tolerance: abs(a - b) < epsilon."),
                "the old single-answer advice must be gone"
            )
        }

        // Same rule, different severities: a configuration difference, not two rules.
        XCTAssertEqual(tqDiag.severity, .error)
        XCTAssertEqual(fpDiag.severity, .warning)
        XCTAssertEqual(tqDiag.message, fpDiag.message)
        XCTAssertEqual(tqDiag.suggestedFix, fpDiag.suggestedFix)
    }

    // MARK: - Negative control

    /// A harness that reports the same count for known-good and known-bad
    /// input is measuring nothing. Assert the counts differ, in both checkers.
    func testNegativeControlKnownGoodAndKnownBadDiffer() async throws {
        let knownBad = """
        import Testing

        @Test func testValue() {
            let actual: Double = fastPath()
            let expected: Double = referenceImplementation()
            #expect(actual == expected)
            #expect(actual == 0.3989422804014327)
        }
        """

        let knownGood = """
        import Testing

        @Test func testValue() {
            let actual: Double = fastPath()
            let expected: Double = referenceImplementation()
            #expect(abs(actual - expected) < 1e-9)
            #expect(actual.bitPattern == expected.bitPattern)
        }
        """

        let badTQ = try await exactEquality(knownBad).count
        let goodTQ = try await exactEquality(knownGood).count
        let badFP = try await fpEquality(knownBad).count
        let goodFP = try await fpEquality(knownGood).count

        XCTAssertEqual(badTQ, 2)
        XCTAssertEqual(goodTQ, 0)
        XCTAssertEqual(badFP, 2)
        XCTAssertEqual(goodFP, 0)
        XCTAssertNotEqual(badTQ, goodTQ, "negative control: the checker must distinguish the two inputs")
        XCTAssertNotEqual(badFP, goodFP, "negative control: the checker must distinguish the two inputs")
    }

    // MARK: - Whole-file disable is honoured by both

    func testWholeFileDisableIsHonouredByBothCheckers() async throws {
        let source = """
        // fp-safety:disable
        import Testing

        @Test func testValue() {
            let actual: Double = fastPath()
            let expected: Double = referenceImplementation()
            #expect(actual == expected)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 0)
        XCTAssertEqual(tq.count, 0)
    }
}
