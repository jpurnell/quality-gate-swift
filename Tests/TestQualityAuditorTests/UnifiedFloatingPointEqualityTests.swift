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

    private func fpDivision(_ source: String) async throws -> [Diagnostic] {
        let result = try await fpSafety.auditSource(source, fileName: fixturePath, configuration: config)
        return result.diagnostics.filter { $0.ruleId == "fp-division-unguarded" }
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

    // MARK: - Defect 1: a static member on a float type is not automatically a float

    /// `Double.dimension` is an `Int` — it comes from a `VectorSpace`
    /// conformance, not from `Double`'s own storage. The rule used to treat
    /// *any* member access on a `Double` base as floating-point, so this was
    /// flagged three times in BusinessMath.
    func testStaticMemberOfUnknownTypeOnAFloatTypeIsNotFlagged() async throws {
        let source = """
        import Testing

        @Test func testDimension() {
            #expect(Double.dimension == 1)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 0, "Double.dimension is an Int; the type of a static member is not known from syntax")
        XCTAssertEqual(tq.count, 0)
    }

    func testUnknownStaticMemberOnAFloatTypeIsNotFlaggedOnEitherSide() async throws {
        let source = """
        import Testing

        @Test func testDimension() {
            #expect(Float.dimension == Double.dimension)
            #expect(Double.componentCount != 3)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 0)
        XCTAssertEqual(tq.count, 0)
    }

    /// The allowlisted static members really are the type, so they still make
    /// the operand floating-point — and they are sentinels, so the comparison
    /// stays exempt. Both lists must agree about them.
    func testAllowlistedStaticMembersRemainSentinelExempt() async throws {
        let source = """
        import Testing

        @Test func testSentinels() {
            let x = compute()
            #expect(x == Double.pi)
            #expect(x == Double.infinity)
            #expect(x == Double.greatestFiniteMagnitude)
            #expect(x == Double.signalingNaN)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 0)
        XCTAssertEqual(tq.count, 0)
    }

    /// `x == nil` asks whether an optional is populated. It is not a
    /// floating-point comparison at all, whatever `x` wraps.
    func testComparisonAgainstNilIsNotFlagged() async throws {
        let source = """
        import Testing

        @Test func testEmptyChains() {
            let rHat: Double? = rHatStatistic([[], []])
            #expect(rHat == nil)
            #expect(rHat != nil)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 0, "`== nil` is an optional-presence test, not a float comparison")
        XCTAssertEqual(tq.count, 0)
    }

    /// An optional float still compares like a float when the other side is one.
    func testOptionalFloatComparedToAFloatIsStillFlagged() async throws {
        let source = """
        import Testing

        @Test func testValues() {
            let a: Double? = firstValue()
            let b: Double? = secondValue()
            #expect(a == b)
        }
        """

        let fp = try await fpEquality(source)
        XCTAssertEqual(fp.count, 1)
    }

    // MARK: - Defect 2: a name binding does not escape the scope that introduced it

    /// The `AdvancedStatisticsTests` shape. `combination` returns an `Int`, but
    /// an unrelated test earlier in the same file declares `let result: Double`,
    /// and the name map was file-wide.
    func testAnIntNamedResultIsNotFlaggedBecauseAnotherFunctionDeclaresADoubleResult() async throws {
        let source = """
        import Testing

        @Test func testMean() {
            let result: Double = mean(of: sample)
            #expect(abs(result - 4.5) < 1e-9)
        }

        @Test func testCombination() {
            let result = combination(10, 3)
            #expect(result == 120)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 0, "`result` in testCombination is a different binding entirely")
        XCTAssertEqual(tq.count, 0)
    }

    func testABindingInsideAClosureDoesNotEscapeIt() async throws {
        let source = """
        import Testing

        @Test func testScopes() {
            [1, 2].forEach { _ in
                let value: Double = compute()
                _ = value
            }
            let value = count(of: sample)
            #expect(value == 7)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 0)
        XCTAssertEqual(tq.count, 0)
    }

    /// Scoping must not blind the rule: a binding is still visible to the
    /// comparison that follows it in the *same* scope.
    func testABindingIsStillVisibleWithinItsOwnScope() async throws {
        let source = """
        import Testing

        @Test func testAgreement() {
            let expected: Double = reference()
            let actual: Double = fastPath()
            #expect(actual == expected)
        }
        """

        let fp = try await fpEquality(source)
        XCTAssertEqual(fp.count, 1)
    }

    // MARK: - Defect 3: collections, and the return types that reveal them

    /// The `DistributionSeedDeterminismTests` shape: `[Double] == [Double]`
    /// with no annotation anywhere, resolvable only through the file-local
    /// helper's declared return type.
    func testIntraFileReturnTypePropagationFindsTheArrayComparison() async throws {
        let source = """
        import Testing

        struct StreamTests {
            private func block(_ draw: (UInt64) -> Double, seed: UInt64) -> [Double] {
                (0..<20).map { draw(seed &+ UInt64($0)) }
            }

            @Test func gammaSeed() {
                let a = block({ sample(seed: $0) }, seed: 42)
                let b = block({ sample(seed: $0) }, seed: 42)
                let c = block({ sample(seed: $0) }, seed: 43)
                #expect(a == b, "Seed 42 must reproduce exactly")
                #expect(a != c, "Seed 43 must not reproduce seed 42")
            }
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 2, "both the same-seed and the different-seed claim must be seen")
        XCTAssertEqual(tq.count, 2)
    }

    /// `try` in front of the call must not hide the return type.
    func testReturnTypePropagationSeesThroughTry() async throws {
        let source = """
        import Testing

        @Test func chiSquaredThrowingSeed() throws {
            func draw(_ seed: UInt64) throws -> [Double] {
                try (0..<20).map { try sample(seed: seed) }
            }
            let a = try draw(42)
            let b = try draw(42)
            #expect(a == b)
        }
        """

        let fp = try await fpEquality(source)
        XCTAssertEqual(fp.count, 1)
    }

    func testExplicitArrayOfDoubleAnnotationIsFlagged() async throws {
        let source = """
        import Testing

        @Test func testStreams() {
            let a: [Double] = firstStream()
            let b: ArraySlice<Double> = secondStream()
            let c: ContiguousArray<Float> = thirdStream()
            #expect(a == b)
            #expect(a != c)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 2)
        XCTAssertEqual(tq.count, 2)
    }

    func testArrayLiteralOfFloatLiteralsIsFlagged() async throws {
        let source = """
        import Testing

        @Test func testWeights() {
            let weights = normalise(input)
            #expect(weights == [0.25, 0.25, 0.5])
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 1)
        XCTAssertEqual(tq.count, 1)
    }

    func testArrayOfIntegerLiteralsIsNotFlagged() async throws {
        let source = """
        import Testing

        @Test func testCounts() {
            let counts = histogram(input)
            #expect(counts == [1, 2, 3])
        }
        """

        let fp = try await fpEquality(source)
        XCTAssertEqual(fp.count, 0)
    }

    /// A collection comparison is elementwise, so the fix has to be elementwise
    /// too — a scalar `bitPattern` comparison does not typecheck against `[Double]`,
    /// and a caller who follows scalar advice writes something that cannot compile.
    func testCollectionDiagnosticStatesTheComparisonIsElementwise() async throws {
        let source = """
        import Testing

        @Test func testStreams() {
            let a: [Double] = firstStream()
            let b: [Double] = secondStream()
            #expect(a == b)
        }
        """

        let found = try await fpEquality(source)
        let diagnostic = try XCTUnwrap(found.first)
        let text = diagnostic.message + " " + (diagnostic.suggestedFix ?? "")
        XCTAssertTrue(text.lowercased().contains("elementwise"), "the diagnostic must say the comparison is elementwise")
        XCTAssertTrue(
            text.contains("zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }"),
            "the bit-identity fix must be spelled elementwise"
        )
        XCTAssertTrue(text.contains("a.count == b.count"), "a count check is part of the elementwise claim")
        XCTAssertFalse(
            text.contains("a.bitPattern == b.bitPattern"),
            "the scalar form is wrong advice here — it does not typecheck against a collection"
        )
    }

    func testCollectionDiagnosticForInequalityIsAlsoElementwise() async throws {
        let source = """
        import Testing

        @Test func testStreams() {
            let a: [Double] = firstStream()
            let b: [Double] = secondStream()
            #expect(a != b)
        }
        """

        let found = try await fpEquality(source)
        let diagnostic = try XCTUnwrap(found.first)
        let text = diagnostic.message + " " + (diagnostic.suggestedFix ?? "")
        XCTAssertTrue(text.lowercased().contains("elementwise"))
        XCTAssertTrue(text.contains("a.count != b.count"))
    }

    /// Scalars keep the scalar advice — the elementwise wording must not leak.
    func testScalarDiagnosticIsUnchanged() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let a: Double = firstValue()
            let b: Double = secondValue()
            #expect(a == b)
        }
        """

        let found = try await fpEquality(source)
        let diagnostic = try XCTUnwrap(found.first)
        let text = diagnostic.message + " " + (diagnostic.suggestedFix ?? "")
        XCTAssertTrue(text.contains("a.bitPattern == b.bitPattern"))
        XCTAssertFalse(text.lowercased().contains("elementwise"))
    }

    // MARK: - Defect 3: the conservative limits

    /// Two declarations of one name that disagree about the return type. The
    /// rule has no overload resolution, so it must decline rather than guess.
    func testOverloadedLocalFunctionIsNotResolved() async throws {
        let source = """
        import Testing

        func stream(_ seed: UInt64) -> [Double] { [] }
        func stream(_ label: String) -> [Int] { [] }

        @Test func testStreams() {
            let a = stream(42)
            let b = stream(43)
            #expect(a == b)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 0, "an overloaded name has no unambiguous return type; do not guess")
        XCTAssertEqual(tq.count, 0)
    }

    /// A function with no explicit return clause is also not resolvable, and it
    /// makes the name ambiguous for any sibling that does declare one.
    func testInferredReturnTypeIsNotResolved() async throws {
        let source = """
        import Testing

        func stream(_ seed: UInt64) { }
        func stream(_ seed: Int) -> [Double] { [] }

        @Test func testStreams() {
            let a = stream(42)
            let b = stream(43)
            #expect(a == b)
        }
        """

        let fp = try await fpEquality(source)
        XCTAssertEqual(fp.count, 0)
    }

    /// The call target is declared somewhere else entirely. There is no
    /// cross-file resolution, so there is nothing to know.
    func testCallToAFunctionDeclaredInAnotherFileIsNotResolved() async throws {
        let source = """
        import Testing

        @Test func testStreams() {
            let a = referenceStream(seed: 42)
            let b = referenceStream(seed: 42)
            #expect(a == b)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        XCTAssertEqual(fp.count, 0, "no cross-file resolution: the return type of referenceStream is unknown")
        XCTAssertEqual(tq.count, 0)
    }

    /// A method call qualified by a receiver is not a bare file-local call, and
    /// the receiver's type is unknown from syntax.
    func testQualifiedMethodCallIsNotResolved() async throws {
        let source = """
        import Testing

        func stream(_ seed: UInt64) -> [Double] { [] }

        @Test func testStreams() {
            let a = engine.stream(42)
            let b = engine.stream(42)
            #expect(a == b)
        }
        """

        let fp = try await fpEquality(source)
        XCTAssertEqual(fp.count, 0)
    }

    /// Two declarations that agree on the return type are not a guess: whichever
    /// overload the compiler picks, the answer is the same. This is the shape
    /// `DistributionSeedDeterminismTests` actually has — two nested `draw`
    /// helpers, both `-> [Double]`.
    func testOverloadsThatAgreeOnTheReturnTypeAreResolved() async throws {
        let source = """
        import Testing

        @Test func first() throws {
            func draw(_ seed: UInt64) throws -> [Double] { [] }
            let a = try draw(42)
            let b = try draw(42)
            #expect(a == b)
        }

        @Test func second() throws {
            func draw(_ seed: UInt64) throws -> [Double] { [] }
            let a = try draw(7)
            let b = try draw(7)
            #expect(a == b)
        }
        """

        let fp = try await fpEquality(source)
        XCTAssertEqual(fp.count, 2)
    }

    // MARK: - The division rule keeps the evidence it had

    /// The two rules ask different questions of the same operand. `fp-equality`
    /// asks "which of three claims is this `==` making?", which is worth raising
    /// on inferred types. `fp-division-unguarded` asks "could this divisor be
    /// zero?", and its answer is a guard in shipping code — so it stays on
    /// direct evidence (an annotation, a literal, a conversion at the site) and
    /// does not follow inference chains. Widening it was a side effect of
    /// teaching the equality rule to see collections, not a decision.
    func testDivisionRuleDoesNotFollowInferredOperandTypes() async throws {
        let source = """
        func scale(_ x: Int) -> Double { Double(x) }

        func average(_ total: Int, _ count: Int) -> Double {
            let n = Double(count)
            let s = scale(total)
            return s / n
        }
        """

        let divisions = try await fpDivision(source)
        XCTAssertEqual(divisions.count, 0, "an inferred type is not enough to demand a zero guard")
    }

    func testDivisionRuleStillFiresOnADeclaredFloatDivisor() async throws {
        let source = """
        func average(_ total: Double, _ count: Double) -> Double {
            let n: Double = count
            return total / n
        }
        """

        let divisions = try await fpDivision(source)
        XCTAssertEqual(divisions.count, 1, "an annotated divisor is direct evidence and still counts")
    }

    /// …but the equality rule *does* follow them: that is the whole point of
    /// defect 3.
    func testEqualityRuleDoesFollowInferredOperandTypes() async throws {
        let source = """
        func scale(_ x: Int) -> Double { Double(x) }

        func agrees(_ a: Int, _ b: Int) -> Bool {
            let first = scale(a)
            let second = scale(b)
            return first == second
        }
        """

        let fp = try await fpEquality(source)
        XCTAssertEqual(fp.count, 1)
    }

    // MARK: - Negative control for the collection rule

    func testNegativeControlCollectionsKnownGoodAndKnownBadDiffer() async throws {
        let knownBad = """
        import Testing

        struct StreamTests {
            private func block(_ seed: UInt64) -> [Double] { [] }

            @Test func testStreams() {
                let a = block(42)
                let b = block(42)
                let c = block(43)
                #expect(a == b)
                #expect(a != c)
            }
        }
        """

        let knownGood = """
        import Testing

        struct StreamTests {
            private func block(_ seed: UInt64) -> [Double] { [] }

            @Test func testStreams() {
                let a = block(42)
                let b = block(42)
                let c = block(43)
                #expect(a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern })
                #expect(a.count != c.count || zip(a, c).contains { $0.bitPattern != $1.bitPattern })
            }
        }
        """

        let badFP = try await fpEquality(knownBad).count
        let goodFP = try await fpEquality(knownGood).count
        let badTQ = try await exactEquality(knownBad).count
        let goodTQ = try await exactEquality(knownGood).count

        XCTAssertEqual(badFP, 2)
        XCTAssertEqual(goodFP, 0)
        XCTAssertEqual(badTQ, 2)
        XCTAssertEqual(goodTQ, 0)
        XCTAssertNotEqual(badFP, goodFP, "negative control: the checker must distinguish the two inputs")
        XCTAssertNotEqual(badTQ, goodTQ, "negative control: the checker must distinguish the two inputs")
    }
}
