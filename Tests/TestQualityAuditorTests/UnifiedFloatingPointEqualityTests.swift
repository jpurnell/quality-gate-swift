import Testing
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
@Suite
struct UnifiedFloatingPointEqualityTests {

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

    @Test
    func manyDigitLiteralIsFlaggedInAssertion() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            #expect(result == 0.3989422804014327)
        }
        """

        let tq = try await exactEquality(source)
        let fp = try await fpEquality(source)
        #expect(tq.count == 1)
        #expect(fp.count == 1)
    }

    @Test
    func manyDigitLiteralIsFlaggedOutsideAnAssertion() async throws {
        let source = """
        func classify() -> Bool {
            let result = compute()
            return result == 0.3989422804014327
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        // fp-safety owns non-assertion sites; test-quality deliberately does not.
        #expect(fp.count == 1)
        #expect(tq.count == 0)
    }

    // MARK: - Must fail: two computed Doubles, no literal anywhere

    /// The coverage hole in `TestQualityAuditor`'s private copy: it required a
    /// `FloatLiteralExprSyntax` on one side, so a comparison of two computed
    /// `Double`s was invisible to it.
    @Test
    func twoComputedDoublesWithNoLiteralAreFlaggedInAssertion() async throws {
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
        #expect(tq.count == 1, "A literal-free comparison of two computed Doubles must be caught")
        #expect(fp.count == 1)
    }

    @Test
    func twoComputedDoublesWithNoLiteralAreFlaggedOutsideAnAssertion() async throws {
        let source = """
        func agrees() -> Bool {
            let expected: Double = referenceImplementation()
            let actual: Double = fastPath()
            return actual == expected
        }
        """

        let fp = try await fpEquality(source)
        #expect(fp.count == 1)
    }

    // MARK: - Must pass: the three unambiguous forms

    @Test
    func toleranceComparisonIsNotFlagged() async throws {
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
        #expect(tq.count == 0)
        #expect(fp.count == 0)
    }

    @Test
    func bitPatternComparisonIsNotFlagged() async throws {
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
        #expect(tq.count == 0, "bitPattern comparison is the unambiguous bit-identity form; do not flag it")
        #expect(fp.count == 0)
    }

    @Test
    func namedIEEEEqualityIsNotFlagged() async throws {
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
        #expect(tq.count == 0)
        #expect(fp.count == 0)
    }

    @Test
    func integerComparisonInvolvingADoubleTypedVariableIsNotFlagged() async throws {
        let source = """
        import Testing

        @Test func testBucket() {
            let ratio: Double = fastPath()
            #expect(Int(ratio * 4) == 2)
        }
        """

        let tq = try await exactEquality(source)
        let fp = try await fpEquality(source)
        #expect(tq.count == 0)
        #expect(fp.count == 0)
    }

    /// `sqrt(-2 * log(1))` is `-0.0`; `==` against `0.0` is the correct
    /// comparison there and a bit-pattern check would fail. Both checkers
    /// exempt the zero sentinel.
    @Test
    func comparisonAgainstZeroSentinelIsNotFlagged() async throws {
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
        #expect(tq.count == 0)
        #expect(fp.count == 0)
    }

    // MARK: - Regression: one marker, honoured by both checkers

    /// The bug this change fixes. A developer reads the failing diagnostic,
    /// applies the marker it names, re-runs, and the *other* checker still
    /// fails on the same line. Both checkers must honour `// fp-safety:disable`.
    @Test
    func canonicalMarkerSuppressesInBothCheckers() async throws {
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

        #expect(fp.count == 0, "fp-safety must honour its own marker")
        #expect(tq.count == 0, "test-quality must honour the same marker — this is the defect")
        #expect(overrides.count == 1, "A suppressed finding must still be recorded as an override, not vanish")
    }

    @Test
    func canonicalMarkerOnTheCommentLineAboveSuppressesInBothCheckers() async throws {
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
        #expect(fp.count == 0)
        #expect(tq.count == 0)
    }

    /// The legacy marker must keep working or every existing suppression in
    /// consumer projects breaks at once.
    @Test
    func legacyTestQualityMarkerStillSuppresses() async throws {
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

        #expect(tq.count == 0)
        #expect(overrides.count == 1)
        #expect(fp.count == 0, "The two markers are one marker set; neither checker may ignore the other's")
    }

    /// An inline marker must not leak onto the following line. 300 sites in
    /// BusinessMath carry a trailing `// fp-safety:disable`; if "the line
    /// above" matched those, every one of them would silently suppress its
    /// neighbour.
    @Test
    func inlineMarkerDoesNotSuppressTheFollowingLine() async throws {
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
        #expect(fp.count == 1, "Only the marked line is suppressed")
    }

    // MARK: - The diagnostic names all three claims

    @Test
    func diagnosticPresentsTheThreeClaimsRatherThanAssertingOne() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let result = compute()
            #expect(result == 0.3989422804014327)
        }
        """

        let tqDiags = try await exactEquality(source)
        let fpDiags = try await fpEquality(source)
        let tqDiag = try #require(tqDiags.first)
        let fpDiag = try #require(fpDiags.first)

        for diagnostic in [tqDiag, fpDiag] {
            let text = diagnostic.message + " " + (diagnostic.suggestedFix ?? "")
            #expect(text.contains("abs(a - b) < epsilon"), "names the tolerance form")
            #expect(text.contains("a.isEqual(to: b)"), "names the IEEE-equality form")
            #expect(text.contains("a.bitPattern == b.bitPattern"), "names the bit-identity form")
            #expect(!(diagnostic.message.contains("Use tolerance: abs(a - b) < epsilon.")), "the old single-answer advice must be gone")
        }

        // Same rule, different severities: a configuration difference, not two rules.
        #expect(tqDiag.severity == .error)
        #expect(fpDiag.severity == .warning)
        #expect(tqDiag.message == fpDiag.message)
        #expect(tqDiag.suggestedFix == fpDiag.suggestedFix)
    }

    // MARK: - Negative control

    /// A harness that reports the same count for known-good and known-bad
    /// input is measuring nothing. Assert the counts differ, in both checkers.
    @Test
    func negativeControlKnownGoodAndKnownBadDiffer() async throws {
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

        #expect(badTQ == 2)
        #expect(goodTQ == 0)
        #expect(badFP == 2)
        #expect(goodFP == 0)
        #expect(badTQ != goodTQ, "negative control: the checker must distinguish the two inputs")
        #expect(badFP != goodFP, "negative control: the checker must distinguish the two inputs")
    }

    // MARK: - Whole-file disable is honoured by both

    @Test
    func wholeFileDisableIsHonouredByBothCheckers() async throws {
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
        #expect(fp.count == 0)
        #expect(tq.count == 0)
    }

    // MARK: - Defect 1: a static member on a float type is not automatically a float

    /// `Double.dimension` is an `Int` — it comes from a `VectorSpace`
    /// conformance, not from `Double`'s own storage. The rule used to treat
    /// *any* member access on a `Double` base as floating-point, so this was
    /// flagged three times in BusinessMath.
    @Test
    func staticMemberOfUnknownTypeOnAFloatTypeIsNotFlagged() async throws {
        let source = """
        import Testing

        @Test func testDimension() {
            #expect(Double.dimension == 1)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        #expect(fp.count == 0, "Double.dimension is an Int; the type of a static member is not known from syntax")
        #expect(tq.count == 0)
    }

    @Test
    func unknownStaticMemberOnAFloatTypeIsNotFlaggedOnEitherSide() async throws {
        let source = """
        import Testing

        @Test func testDimension() {
            #expect(Float.dimension == Double.dimension)
            #expect(Double.componentCount != 3)
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        #expect(fp.count == 0)
        #expect(tq.count == 0)
    }

    /// The allowlisted static members really are the type, so they still make
    /// the operand floating-point — and they are sentinels, so the comparison
    /// stays exempt. Both lists must agree about them.
    @Test
    func allowlistedStaticMembersRemainSentinelExempt() async throws {
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
        #expect(fp.count == 0)
        #expect(tq.count == 0)
    }

    /// `x == nil` asks whether an optional is populated. It is not a
    /// floating-point comparison at all, whatever `x` wraps.
    @Test
    func comparisonAgainstNilIsNotFlagged() async throws {
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
        #expect(fp.count == 0, "`== nil` is an optional-presence test, not a float comparison")
        #expect(tq.count == 0)
    }

    /// An optional float still compares like a float when the other side is one.
    @Test
    func optionalFloatComparedToAFloatIsStillFlagged() async throws {
        let source = """
        import Testing

        @Test func testValues() {
            let a: Double? = firstValue()
            let b: Double? = secondValue()
            #expect(a == b)
        }
        """

        let fp = try await fpEquality(source)
        #expect(fp.count == 1)
    }

    // MARK: - Defect 2: a name binding does not escape the scope that introduced it

    /// The `AdvancedStatisticsTests` shape. `combination` returns an `Int`, but
    /// an unrelated test earlier in the same file declares `let result: Double`,
    /// and the name map was file-wide.
    @Test
    func anIntNamedResultIsNotFlaggedBecauseAnotherFunctionDeclaresADoubleResult() async throws {
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
        #expect(fp.count == 0, "`result` in testCombination is a different binding entirely")
        #expect(tq.count == 0)
    }

    @Test
    func aBindingInsideAClosureDoesNotEscapeIt() async throws {
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
        #expect(fp.count == 0)
        #expect(tq.count == 0)
    }

    /// Scoping must not blind the rule: a binding is still visible to the
    /// comparison that follows it in the *same* scope.
    @Test
    func aBindingIsStillVisibleWithinItsOwnScope() async throws {
        let source = """
        import Testing

        @Test func testAgreement() {
            let expected: Double = reference()
            let actual: Double = fastPath()
            #expect(actual == expected)
        }
        """

        let fp = try await fpEquality(source)
        #expect(fp.count == 1)
    }

    // MARK: - Defect 3: collections, and the return types that reveal them

    /// The `DistributionSeedDeterminismTests` shape: `[Double] == [Double]`
    /// with no annotation anywhere, resolvable only through the file-local
    /// helper's declared return type.
    @Test
    func intraFileReturnTypePropagationFindsTheArrayComparison() async throws {
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
        #expect(fp.count == 2, "both the same-seed and the different-seed claim must be seen")
        #expect(tq.count == 2)
    }

    /// `try` in front of the call must not hide the return type.
    @Test
    func returnTypePropagationSeesThroughTry() async throws {
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
        #expect(fp.count == 1)
    }

    @Test
    func explicitArrayOfDoubleAnnotationIsFlagged() async throws {
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
        #expect(fp.count == 2)
        #expect(tq.count == 2)
    }

    @Test
    func arrayLiteralOfFloatLiteralsIsFlagged() async throws {
        let source = """
        import Testing

        @Test func testWeights() {
            let weights = normalise(input)
            #expect(weights == [0.25, 0.25, 0.5])
        }
        """

        let fp = try await fpEquality(source)
        let tq = try await exactEquality(source)
        #expect(fp.count == 1)
        #expect(tq.count == 1)
    }

    @Test
    func arrayOfIntegerLiteralsIsNotFlagged() async throws {
        let source = """
        import Testing

        @Test func testCounts() {
            let counts = histogram(input)
            #expect(counts == [1, 2, 3])
        }
        """

        let fp = try await fpEquality(source)
        #expect(fp.count == 0)
    }

    /// A collection comparison is elementwise, so the fix has to be elementwise
    /// too — a scalar `bitPattern` comparison does not typecheck against `[Double]`,
    /// and a caller who follows scalar advice writes something that cannot compile.
    @Test
    func collectionDiagnosticStatesTheComparisonIsElementwise() async throws {
        let source = """
        import Testing

        @Test func testStreams() {
            let a: [Double] = firstStream()
            let b: [Double] = secondStream()
            #expect(a == b)
        }
        """

        let found = try await fpEquality(source)
        let diagnostic = try #require(found.first)
        let text = diagnostic.message + " " + (diagnostic.suggestedFix ?? "")
        #expect(text.lowercased().contains("elementwise"), "the diagnostic must say the comparison is elementwise")
        #expect(text.contains("zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }"), "the bit-identity fix must be spelled elementwise")
        #expect(text.contains("a.count == b.count"), "a count check is part of the elementwise claim")
        #expect(!(text.contains("a.bitPattern == b.bitPattern")), "the scalar form is wrong advice here — it does not typecheck against a collection")
    }

    @Test
    func collectionDiagnosticForInequalityIsAlsoElementwise() async throws {
        let source = """
        import Testing

        @Test func testStreams() {
            let a: [Double] = firstStream()
            let b: [Double] = secondStream()
            #expect(a != b)
        }
        """

        let found = try await fpEquality(source)
        let diagnostic = try #require(found.first)
        let text = diagnostic.message + " " + (diagnostic.suggestedFix ?? "")
        #expect(text.lowercased().contains("elementwise"))
        #expect(text.contains("a.count != b.count"))
    }

    /// Scalars keep the scalar advice — the elementwise wording must not leak.
    @Test
    func scalarDiagnosticIsUnchanged() async throws {
        let source = """
        import Testing

        @Test func testValue() {
            let a: Double = firstValue()
            let b: Double = secondValue()
            #expect(a == b)
        }
        """

        let found = try await fpEquality(source)
        let diagnostic = try #require(found.first)
        let text = diagnostic.message + " " + (diagnostic.suggestedFix ?? "")
        #expect(text.contains("a.bitPattern == b.bitPattern"))
        #expect(!(text.lowercased().contains("elementwise")))
    }

    // MARK: - Defect 3: the conservative limits

    /// Two declarations of one name that disagree about the return type. The
    /// rule has no overload resolution, so it must decline rather than guess.
    @Test
    func overloadedLocalFunctionIsNotResolved() async throws {
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
        #expect(fp.count == 0, "an overloaded name has no unambiguous return type; do not guess")
        #expect(tq.count == 0)
    }

    /// A function with no explicit return clause is also not resolvable, and it
    /// makes the name ambiguous for any sibling that does declare one.
    @Test
    func inferredReturnTypeIsNotResolved() async throws {
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
        #expect(fp.count == 0)
    }

    /// The call target is declared somewhere else entirely. There is no
    /// cross-file resolution, so there is nothing to know.
    @Test
    func callToAFunctionDeclaredInAnotherFileIsNotResolved() async throws {
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
        #expect(fp.count == 0, "no cross-file resolution: the return type of referenceStream is unknown")
        #expect(tq.count == 0)
    }

    /// A method call qualified by a receiver is not a bare file-local call, and
    /// the receiver's type is unknown from syntax.
    @Test
    func qualifiedMethodCallIsNotResolved() async throws {
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
        #expect(fp.count == 0)
    }

    /// Two declarations that agree on the return type are not a guess: whichever
    /// overload the compiler picks, the answer is the same. This is the shape
    /// `DistributionSeedDeterminismTests` actually has — two nested `draw`
    /// helpers, both `-> [Double]`.
    @Test
    func overloadsThatAgreeOnTheReturnTypeAreResolved() async throws {
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
        #expect(fp.count == 2)
    }

    // MARK: - The division rule keeps the evidence it had

    /// The two rules ask different questions of the same operand. `fp-equality`
    /// asks "which of three claims is this `==` making?", which is worth raising
    /// on inferred types. `fp-division-unguarded` asks "could this divisor be
    /// zero?", and its answer is a guard in shipping code — so it does not follow
    /// a function's return type. Widening it was a side effect of teaching the
    /// equality rule to see collections, not a decision.
    @Test
    func divisionRuleDoesNotFollowReturnTypes() async throws {
        let source = """
        func scale(_ x: Int) -> Double { Double(x) }

        func average(_ total: Int, _ count: Int) -> Double {
            let s = scale(total)
            let n = scale(count)
            return s / n
        }
        """

        let divisions = try await fpDivision(source)
        #expect(divisions.count == 0, "a return type read from another declaration is not enough to demand a zero guard")
    }

    /// This test used to assert the opposite, in one fixture with the case
    /// above: `let n = Double(count)` was called an inference chain alongside
    /// the return type, and neither was examined. They are not the same thing.
    /// A conversion bound to a `let` one line above its use is a conversion
    /// written at the site, and refusing it made `s / Double(count)` a finding
    /// and `s / n` not one — a verdict that turned on the divisor having a name.
    @Test
    func divisionRuleExaminesAConversionBoundLocal() async throws {
        let source = """
        func scale(_ x: Int) -> Double { Double(x) }

        func average(_ total: Int, _ count: Int) -> Double {
            let n = Double(count)
            let s = scale(total)
            return s / n
        }
        """

        let divisions = try await fpDivision(source)
        #expect(divisions.count == 1, "a local carries the evidence of its initializer")
        #expect(divisions.first?.lineNumber == 6)
    }

    @Test
    func divisionRuleStillFiresOnADeclaredFloatDivisor() async throws {
        let source = """
        func average(_ total: Double, _ count: Double) -> Double {
            let n: Double = count
            return total / n
        }
        """

        let divisions = try await fpDivision(source)
        #expect(divisions.count == 1, "an annotated divisor is direct evidence and still counts")
    }

    /// …but the equality rule *does* follow them: that is the whole point of
    /// defect 3.
    @Test
    func equalityRuleDoesFollowInferredOperandTypes() async throws {
        let source = """
        func scale(_ x: Int) -> Double { Double(x) }

        func agrees(_ a: Int, _ b: Int) -> Bool {
            let first = scale(a)
            let second = scale(b)
            return first == second
        }
        """

        let fp = try await fpEquality(source)
        #expect(fp.count == 1)
    }

    // MARK: - Negative control for the collection rule

    @Test
    func negativeControlCollectionsKnownGoodAndKnownBadDiffer() async throws {
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

        #expect(badFP == 2)
        #expect(goodFP == 0)
        #expect(badTQ == 2)
        #expect(goodTQ == 0)
        #expect(badFP != goodFP, "negative control: the checker must distinguish the two inputs")
        #expect(badTQ != goodTQ, "negative control: the checker must distinguish the two inputs")
    }
}
