import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

/// Runs the `fallback` rules over a source string and returns the
/// int-conversion findings only.
private func intConversionFindings(
    _ source: String,
    filePath: String = "Sources/Curves/DiscountCurve.swift"
) -> [Diagnostic] {
    FallbackRules.audit(source: source, fileName: filePath)
        .diagnostics
        .filter { $0.ruleId == FallbackRuleID.intConversionUnguarded }
}

// MARK: - The three crashes
//
// Fixtures are the real sites from BusinessMath at `464cf939`, reduced. Each
// took the process down on a NaN.

@Suite("fallback.int-conversion-unguarded: the sites that crashed")
struct FallbackIntConversionCrashSiteTests {

    @Test("DiscountCurve.bootstrap: Int(entry.tenor) on a tuple label declared Double")
    func flagsMemberOfTupleLabel() {
        let code = """
        struct DiscountCurve {
            static func bootstrap(parRates: [(tenor: Double, rate: Double)]) -> [Int] {
                var years: [Int] = []
                for entry in parRates {
                    let year = Int(entry.tenor)
                    years.append(year)
                }
                return years
            }
        }
        """
        let findings = intConversionFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 5)
        #expect(findings.first?.severity == .error)
    }

    @Test("DiscountCurve.bootstrap: Int(sorted.last?.tenor ?? 0) through optional chaining")
    func flagsOptionalChainedMember() {
        let code = """
        func maxTenor(parRates: [(tenor: Double, rate: Double)]) -> Int {
            let sorted = parRates
            return Int(sorted.last?.tenor ?? 0)
        }
        """
        let findings = intConversionFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 3)
    }

    @Test("optimizeIntegerProjects: Int(budget) on a generic parameter constrained to Real")
    func flagsGenericParameterOnType() {
        let code = """
        struct CapitalAllocationOptimizer<T> where T: Real & Sendable {
            struct Project { let capitalRequired: T }

            func optimizeIntegerProjects(projects: [Project], budget: T) -> Int {
                let maxBudget = Int(budget)
                var total = 0
                for project in projects {
                    let cost = Int(project.capitalRequired)
                    total += cost
                }
                return min(total, maxBudget)
            }
        }
        """
        let findings = intConversionFindings(code)
        #expect(findings.map(\.lineNumber) == [5, 8])
    }
}

// MARK: - What counts as guarded

@Suite("fallback.int-conversion-unguarded: what counts as guarded")
struct FallbackIntConversionGuardTests {

    @Test("A parameter declared Double, no guard at all")
    func flagsUnguardedParameter() {
        let code = """
        func year(tenor: Double) -> Int {
            return Int(tenor)
        }
        """
        let findings = intConversionFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 2)
    }

    @Test("isFinite alone is not enough: Int(1e300) traps and 1e300 is finite")
    func flagsFinitenessWithoutRange() {
        let code = """
        func year(tenor: Double) -> Int {
            guard tenor.isFinite else { return 0 }
            return Int(tenor)
        }
        """
        let findings = intConversionFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 3)
        #expect(findings.first?.message.contains("isFinite") == true)
        #expect(findings.first?.message.contains("1e300") == true)
    }

    @Test("An upper bound alone is not enough: Int(-1e300) traps too")
    func flagsUpperBoundWithoutLowerBound() {
        let code = """
        func year(tenor: Double) -> Int {
            guard tenor.isFinite, tenor < 1_000_000 else { return 0 }
            return Int(tenor)
        }
        """
        #expect(intConversionFindings(code).count == 1)
    }

    @Test("A range check alone is not enough: the campaign found one written as two negations")
    func flagsRangeWithoutFiniteness() {
        let code = """
        func year(tenor: Double) -> Int {
            let belowZero = tenor < 0
            let aboveLimit = tenor > 1_000
            guard !belowZero, !aboveLimit else { return 0 }
            return Int(tenor)
        }
        """
        #expect(intConversionFindings(code).count == 1)
    }

    // BusinessMath `distributionGamma.swift:209`, flagged by the first draft of
    // this rule and correct as written. A guard proceeds only when every
    // condition is true, and no comparison with a NaN is true.
    @Test("Bounds asserted by a guard reject a NaN without isFinite: no finding")
    func acceptsBoundsAssertedByGuard() {
        let code = """
        func wholeShape(shape: Double) -> Int? {
            guard shape > 0, shape <= 1_000_000 else { return nil }
            return Int(shape)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("Bounds asserted by a guard, joined with &&: no finding")
    func acceptsConjoinedBoundsAssertedByGuard() {
        let code = """
        func wholeShape(shape: Double) -> Int? {
            guard shape > 0 && shape <= 1_000_000 else { return nil }
            return Int(shape)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("A magnitude bound asserted by a guard: no finding")
    func acceptsMagnitudeAssertedByGuard() {
        let code = """
        func year(tenor: Double) -> Int {
            guard abs(tenor) < 1e15 else { return 0 }
            return Int(tenor)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("A guard joined with || asserts neither side")
    func flagsDisjunctionInGuard() {
        let code = """
        func wholeShape(shape: Double, force: Bool) -> Int? {
            guard force || shape > 0 && shape <= 1_000_000 else { return nil }
            return Int(shape)
        }
        """
        #expect(intConversionFindings(code).count == 1)
    }

    @Test("An `if` that tests the range asserts nothing about the code after it")
    func flagsBoundsInIfCondition() {
        let code = """
        func wholeShape(shape: Double) -> Int {
            if shape > 0, shape <= 1_000_000 { log() }
            return Int(shape)
        }
        """
        #expect(intConversionFindings(code).count == 1)
    }

    // BusinessMath `combination.swift:94`. An upper bound asserted, no lower one.
    @Test("A guard that asserts only an upper bound leaves -1e300")
    func flagsUpperBoundOnlyAssertedByGuard() {
        let code = """
        func combination(n: Int, r: Int) -> Int {
            let result: Double = combinationDouble(n, c: r)
            guard result <= Double(Int.max) else { return 0 }
            return Int(result)
        }
        """
        let findings = intConversionFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 4)
    }

    @Test("Finite and bounded on both sides: no finding")
    func acceptsFiniteAndTwoSidedRange() {
        let code = """
        func year(tenor: Double) -> Int {
            guard tenor.isFinite, tenor >= 0, tenor < 1_000 else { return 0 }
            return Int(tenor)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("Finite and bounded in magnitude through abs: no finding")
    func acceptsFiniteAndAbsBound() {
        let code = """
        func year(tenor: Double) -> Int {
            guard tenor.isFinite, abs(tenor) < Double(Int.max) else { return 0 }
            return Int(tenor)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("Finite and bounded in magnitude through .magnitude: no finding")
    func acceptsFiniteAndMagnitudeBound() {
        let code = """
        func year(tenor: Double) -> Int {
            guard tenor.isFinite, tenor.magnitude < 1e15 else { return 0 }
            return Int(tenor)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("Finite and inside a closed range: no finding")
    func acceptsFiniteAndRangeContains() {
        let code = """
        func year(tenor: Double) -> Int {
            guard tenor.isFinite, (0...1_000).contains(tenor) else { return 0 }
            return Int(tenor)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("The guard is on a member, and so is the conversion: no finding")
    func acceptsGuardOnMember() {
        let code = """
        struct Entry { let tenor: Double }
        func year(entry: Entry) -> Int {
            guard entry.tenor.isFinite, abs(entry.tenor) < 1e15 else { return 0 }
            return Int(entry.tenor)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("The guard is on an alias of the converted value: no finding")
    func acceptsGuardOnAlias() {
        let code = """
        func allocate<T: BinaryFloatingPoint>(budget: T) -> Int {
            let sizable = Double(budget)
            guard sizable.isFinite, abs(sizable) < Double(Int.max) else { return 0 }
            return Int(budget)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("A guard written after the conversion guards nothing")
    func flagsGuardAfterConversion() {
        let code = """
        func year(tenor: Double) -> Int {
            let year = Int(tenor)
            guard tenor.isFinite, abs(tenor) < 1e15 else { return 0 }
            return year
        }
        """
        let findings = intConversionFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 2)
    }

    @Test("A guard in a different function guards nothing here")
    func flagsGuardInSiblingFunction() {
        let code = """
        func checked(tenor: Double) -> Bool {
            tenor.isFinite && abs(tenor) < 1e15
        }
        func year(tenor: Double) -> Int {
            return Int(tenor)
        }
        """
        let findings = intConversionFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 5)
    }

    @Test("Int(exactly:) returns nil instead of trapping: no finding")
    func acceptsExactlyInitializer() {
        let code = """
        func year(tenor: Double) -> Int? {
            return Int(exactly: tenor.rounded(.towardZero))
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("The suggested fix names Int(exactly:) and the rounding it needs")
    func suggestedFixNamesExactly() {
        let code = """
        func year(tenor: Double) -> Int {
            return Int(tenor)
        }
        """
        let fix = intConversionFindings(code).first?.suggestedFix ?? ""
        #expect(fix.contains("Int(exactly:"))
        #expect(fix.contains(".rounded(.towardZero)"))
    }
}

// MARK: - Where the floating-point evidence comes from

@Suite("fallback.int-conversion-unguarded: type evidence")
struct FallbackIntConversionEvidenceTests {

    @Test("A local annotated Double")
    func flagsAnnotatedLocal() {
        let code = """
        func f() -> Int {
            let ratio: Double = compute()
            return Int(ratio)
        }
        """
        #expect(intConversionFindings(code).map(\.lineNumber) == [3])
    }

    @Test("A local initialised from a floating-point parameter carries the type")
    func flagsLocalBoundFromFloatingPointExpression() {
        let code = """
        func f(rate: Double) -> Int {
            let scaled = rate * 1_000_000
            return Int(scaled)
        }
        """
        #expect(intConversionFindings(code).map(\.lineNumber) == [3])
    }

    @Test("Arithmetic on a floating-point name inside the conversion")
    func flagsArithmeticArgument() {
        let code = """
        func f(coefficient: Double) -> Int {
            return Int(coefficient * 1_000_000)
        }
        """
        #expect(intConversionFindings(code).map(\.lineNumber) == [2])
    }

    @Test("A rounding call does not make a NaN representable")
    func flagsThroughRounding() {
        let code = """
        func f(x: Double) -> Int {
            let a = Int(x.rounded())
            let b = Int(floor(x))
            return a + b
        }
        """
        #expect(intConversionFindings(code).map(\.lineNumber) == [2, 3])
    }

    @Test("A generic parameter constrained in the function's own clause")
    func flagsGenericParameterOnFunction() {
        let code = """
        func f<T: BinaryFloatingPoint>(x: T) -> Int {
            return Int(x)
        }
        """
        #expect(intConversionFindings(code).map(\.lineNumber) == [2])
    }

    @Test("A generic parameter constrained by an extension's where clause")
    func flagsGenericParameterOnExtension() {
        let code = """
        extension Matrix where Element: FloatingPoint {
            func bucket(of value: Element) -> Int {
                return Int(value)
            }
        }
        """
        #expect(intConversionFindings(code).map(\.lineNumber) == [3])
    }

    @Test("A stored property declared Double, read through self")
    func flagsStoredProperty() {
        let code = """
        struct Schedule {
            let periods: Double
            func count() -> Int {
                return Int(periods)
            }
        }
        """
        #expect(intConversionFindings(code).map(\.lineNumber) == [4])
    }

    @Test("The fixed-width integer types trap the same way")
    func flagsFixedWidthIntegerTypes() {
        let code = """
        func f(x: Double) -> Int32 {
            let small = Int32(x)
            let unsigned = UInt(x)
            return small + Int32(unsigned)
        }
        """
        #expect(intConversionFindings(code).map(\.lineNumber) == [2, 3])
    }

    // MARK: Must not flag

    @Test("An integer parameter is not a finding")
    func ignoresIntegerParameter() {
        let code = """
        func f(count: Int64) -> Int {
            return Int(count)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("A name whose type is not known is skipped, not guessed")
    func ignoresUnknownName() {
        let code = """
        func f() -> Int {
            return Int(somethingFromAnotherFile)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("A member whose declaration is in another file is skipped")
    func ignoresUnknownMember() {
        let code = """
        func f(entry: Entry) -> Int {
            return Int(entry.tenor)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("A member name declared with two different types in one file is ambiguous, so skipped")
    func ignoresAmbiguousMember() {
        let code = """
        struct Bond { let tenor: Double }
        struct Slot { let tenor: Int }
        func f(slot: Slot) -> Int {
            return Int(slot.tenor)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("A literal is known at compile time")
    func ignoresLiterals() {
        let code = """
        func f() -> Int {
            let a = Int(1e-10)
            let b = Int(2.5)
            return a + b
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    // This repository, `ReviewStore.swift:142`.
    @Test("A static let with a literal value is a constant, read through Self")
    func ignoresStaticConstant() {
        let code = """
        struct ReviewStore {
            static let bridgeDeadline: TimeInterval = 30
            func message() -> String {
                return "Timed out after \\(Int(Self.bridgeDeadline))s"
            }
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("A local let with a literal value is a constant")
    func ignoresLocalConstant() {
        let code = """
        func f() -> Int {
            let limit: Double = 2.5
            return Int(limit)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("A var with a literal value is only where it started")
    func flagsVariableInitialisedFromLiteral() {
        let code = """
        func f() -> Int {
            var total: Double = 0.0
            total = accumulate()
            return Int(total)
        }
        """
        #expect(intConversionFindings(code).map(\.lineNumber) == [4])
    }

    @Test("A value converted up from an integer cannot be NaN")
    func ignoresIntegerDerivedArgument() {
        let code = """
        func f(count: Int) -> Int {
            return Int(Double(count) * 0.95)
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("A labelled initialiser is a different conversion")
    func ignoresLabelledInitialisers() {
        let code = """
        func f(x: Double, bits: UInt64) -> Int {
            let a = Int(truncatingIfNeeded: bits)
            let b = Int(clamping: bits)
            let c = Int(bitPattern: UInt(bits))
            return a + b + c
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("A parameter shadows a floating-point property of the same name")
    func innerBindingShadowsOuter() {
        let code = """
        struct Schedule {
            let periods: Double
            func count(periods: Int) -> Int {
                return Int(periods)
            }
        }
        """
        #expect(intConversionFindings(code).isEmpty)
    }

    @Test("An inout Double parameter is a Double")
    func flagsInoutParameter() {
        let code = """
        func settle(_ x: inout Double) -> Int {
            x *= 2
            return Int(x)
        }
        """
        let findings = intConversionFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 3)
    }

    @Test("Test files are not production code")
    func skipsTestFiles() {
        let code = """
        func year(tenor: Double) -> Int {
            return Int(tenor)
        }
        """
        let findings = intConversionFindings(code, filePath: "Tests/CurveTests/DiscountCurveTests.swift")
        #expect(findings.isEmpty)
    }
}
