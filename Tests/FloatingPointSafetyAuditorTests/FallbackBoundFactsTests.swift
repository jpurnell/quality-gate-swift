import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

/// The lines `fallback.int-conversion-unguarded` reports in `source`.
private func unguardedLines(
    _ source: String,
    filePath: String = "Sources/Statistics/Quantile.swift"
) -> [Int] {
    FallbackRules.audit(source: source, fileName: filePath)
        .diagnostics
        .filter { $0.ruleId == FallbackRuleID.intConversionUnguarded }
        .compactMap(\.lineNumber)
}

/// How many integer conversions of a floating-point value `source` holds.
private func conversionsExamined(_ source: String) -> Int {
    FallbackRules.audit(source: source, fileName: "Sources/Statistics/Quantile.swift").conversionsExamined
}

// Every fixture is a real site from the 2026-10-09 portfolio survey, reduced. Each
// accepted shape is paired with the nearest shape that still traps.

// MARK: - Named range constants

@Suite("fallback.int-conversion-unguarded: guard namedRange.contains(x)")
struct FallbackNamedRangeTests {

    @Test("SwiftExcelFunctions T.DIST.2T: a static Range<Double> with literal bounds, used bare")
    func acceptsStaticRangeConstantInSameType() {
        let code = """
        enum BuiltinStatisticalDistributions {
            static let degreesOfFreedomRange: Range<Double> = 1..<1e10

            static func tDistTwoTailed(x: Double, df: Double) -> Int? {
                guard x >= 0, degreesOfFreedomRange.contains(df) else { return nil }
                return Int(df.rounded(.towardZero))
            }
        }
        """
        #expect(unguardedLines(code) == [])
        #expect(conversionsExamined(code) == 1)
    }

    @Test("The same constant, written through its type")
    func acceptsQualifiedRangeConstant() {
        let code = """
        enum BuiltinStatisticalDistributions {
            static let degreesOfFreedomRange: Range<Double> = 1..<1e10
        }

        func chiSquareInverse(p: Double, df: Double) -> Int? {
            guard p >= 0, p <= 1,
                  BuiltinStatisticalDistributions.degreesOfFreedomRange.contains(df)
            else { return nil }
            return Int(df.rounded(.towardZero))
        }
        """
        #expect(unguardedLines(code) == [])
    }

    @Test("A closed range, a negative bound and no annotation")
    func acceptsClosedRangeWithNegativeBound() {
        let code = """
        struct Dial {
            static let travel = -90.0...90.0

            func step(angle: Double) -> Int {
                guard Self.travel.contains(angle) else { return 0 }
                return Int(angle)
            }
        }
        """
        #expect(unguardedLines(code) == [])
    }

    @Test("A range held in a var can be reassigned, and bounds nothing")
    func flagsVarRange() {
        let code = """
        enum Limits {
            static var degreesOfFreedomRange: Range<Double> = 1..<1e10

            static func whole(df: Double) -> Int? {
                guard degreesOfFreedomRange.contains(df) else { return nil }
                return Int(df.rounded(.towardZero))
            }
        }
        """
        #expect(unguardedLines(code) == [6])
    }

    @Test("A range whose upper bound is infinite contains 1e300")
    func flagsInfiniteBound() {
        let code = """
        enum Limits {
            static let positive: ClosedRange<Double> = 1...Double.infinity

            static func whole(df: Double) -> Int? {
                guard positive.contains(df) else { return nil }
                return Int(df.rounded(.towardZero))
            }
        }
        """
        #expect(unguardedLines(code) == [6])
    }

    @Test("A range built from a parameter is not a constant")
    func flagsNonLiteralBound() {
        let code = """
        struct Limits {
            let ceiling: Double
            var allowed: ClosedRange<Double> { 0...ceiling }

            func whole(df: Double) -> Int? {
                guard allowed.contains(df) else { return nil }
                return Int(df.rounded(.towardZero))
            }
        }
        """
        #expect(unguardedLines(code) == [7])
    }

    @Test("A parameter that shares the constant's name is not the constant")
    func flagsParameterShadowingTheConstant() {
        let code = """
        enum Limits {
            static let allowed: ClosedRange<Double> = 0...100

            static func whole(df: Double, allowed: Set<Double>) -> Int? {
                guard allowed.contains(df) else { return nil }
                return Int(df.rounded(.towardZero))
            }
        }
        """
        #expect(unguardedLines(code) == [6])
    }

    @Test("Membership tested but not asserted lets a NaN through")
    func flagsUnassertedMembership() {
        let code = """
        enum Limits {
            static let allowed: ClosedRange<Double> = 0...100

            static func whole(df: Double) -> Int {
                if !allowed.contains(df) { print("out of range") }
                return Int(df.rounded(.towardZero))
            }
        }
        """
        #expect(unguardedLines(code) == [6])
    }
}

// MARK: - Swift.abs

@Suite("fallback.int-conversion-unguarded: module-qualified Swift.abs is a magnitude bound")
struct FallbackQualifiedMagnitudeTests {

    @Test("SwiftExcelFunctions realOddRoot: guard Swift.abs(rounded) < 1e15")
    func acceptsQualifiedAbs() {
        let code = """
        func realOddRoot(of base: Double, exponent: Double) -> Double? {
            guard base < 0, exponent != 0, exponent.isFinite else { return nil }
            let reciprocal = 1 / exponent
            let rounded = reciprocal.rounded()
            guard Swift.abs(reciprocal - rounded) < 1e-9, Swift.abs(rounded) < 1e15 else {
                return nil
            }
            guard Int(rounded) % 2 != 0 else { return nil }
            return -1
        }
        """
        #expect(unguardedLines(code) == [])
        #expect(conversionsExamined(code) == 1)
    }

    @Test("Swift.abs on a different value bounds nothing about this one")
    func flagsQualifiedAbsOfAnotherValue() {
        let code = """
        func realOddRoot(of base: Double, exponent: Double) -> Double? {
            guard base < 0, exponent != 0, exponent.isFinite else { return nil }
            let reciprocal = 1 / exponent
            let rounded = reciprocal.rounded()
            guard Swift.abs(base) < 1e15 else {
                return nil
            }
            guard Int(rounded) % 2 != 0 else { return nil }
            return -1
        }
        """
        #expect(unguardedLines(code) == [8])
    }

    @Test("A lower bound on a magnitude is true of 1e300")
    func flagsQualifiedAbsLowerBound() {
        let code = """
        func whole(_ value: Double) -> Int {
            guard Swift.abs(value) > 1e-9 else { return 0 }
            return Int(value)
        }
        """
        #expect(unguardedLines(code) == [3])
    }
}

// `magnitudeArgument` lives in the fact collector `fp-division-unguarded` reads too, so
// the qualified spelling changes what that rule accepts. Pinned here, in both directions.

@Suite("fp-division-unguarded: Swift.abs(d) > threshold is the same test as abs(d) > threshold")
struct FallbackQualifiedMagnitudeDivisorTests {

    private func divisionLines(_ source: String) -> [Int] {
        FloatingPointRules.audit(
            source: source,
            fileName: "Sources/Example/test.swift",
            options: .sources(checkDivisionGuards: true)
        ).diagnostics
            .filter { $0.ruleId == "fp-division-unguarded" }
            .compactMap(\.lineNumber)
    }

    @Test("A divisor guarded through Swift.abs is guarded")
    func acceptsQualifiedAbsOnDivisor() {
        let code = """
        func ratio(x: Double, d: Double) -> Double {
            guard Swift.abs(d) > 1e-9 else { return 0 }
            return x / d
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("Swift.abs of another value leaves the divisor unguarded")
    func flagsQualifiedAbsOfAnotherValue() {
        let code = """
        func ratio(x: Double, d: Double) -> Double {
            guard Swift.abs(x) > 1e-9 else { return 0 }
            return x / d
        }
        """
        #expect(divisionLines(code) == [3])
    }
}

// MARK: - Bounds carried through a local

@Suite("fallback.int-conversion-unguarded: bounds carried through min, max and finite products")
struct FallbackCarriedBoundTests {

    @Test("BusinessMath quantile: a NaN-tested value clamped to 0...1, times an integer count")
    func acceptsClampedUnitIntervalTimesCount() {
        let code = """
        public func quantile<T: BinaryFloatingPoint>(sorted: [T], p: T) -> T {
            let n = sorted.count
            guard n > 0 else { return T.nan }
            guard !p.isNaN else { return T.nan }
            let clamped = Swift.min(Swift.max(p, T.zero), T(1))
            let position = clamped * T(n - 1)
            let lowerPosition = position.rounded(.down)
            let lowerIndex = Int(lowerPosition)
            return sorted[lowerIndex]
        }
        """
        #expect(unguardedLines(code) == [])
        #expect(conversionsExamined(code) == 1)
    }

    @Test("The same clamp with nothing asking about a NaN still propagates one into Int")
    func flagsClampOfUntestedValue() {
        let code = """
        public func quantile<T: BinaryFloatingPoint>(sorted: [T], p: T) -> T {
            let n = sorted.count
            guard n > 0 else { return T.nan }
            let clamped = Swift.min(Swift.max(p, T.zero), T(1))
            let position = clamped * T(n - 1)
            let lowerPosition = position.rounded(.down)
            let lowerIndex = Int(lowerPosition)
            return sorted[lowerIndex]
        }
        """
        #expect(unguardedLines(code) == [7])
    }

    @Test("min(x, .infinity) is no upper bound")
    func flagsMinAgainstInfinity() {
        let code = """
        func slot(p: Double, count: Int) -> Int {
            guard !p.isNaN else { return 0 }
            let clamped = min(max(p, 0), .infinity)
            let position = clamped * Double(count)
            return Int(position)
        }
        """
        #expect(unguardedLines(code) == [5])
    }

    @Test("min(x, .greatestFiniteMagnitude) is finite and far outside Int")
    func flagsMinAgainstGreatestFiniteMagnitude() {
        let code = """
        func slot(p: Double) -> Int {
            guard !p.isNaN else { return 0 }
            let clamped = min(max(p, 0), Double.greatestFiniteMagnitude)
            return Int(clamped)
        }
        """
        #expect(unguardedLines(code) == [4])
    }

    @Test("A clamp with the value second returns the bound for a NaN, and so is bounded")
    func acceptsClampThatAbsorbs() {
        let code = """
        func slot(p: Double) -> Int {
            let clamped = max(0.0, min(100.0, p))
            return Int(clamped)
        }
        """
        // `min(100.0, p)` is 100 when `p` is a NaN: the conversion cannot trap. That the
        // clamp answers for a NaN is `fallback.clamp-absorbs-nan`'s finding, not this rule's.
        #expect(unguardedLines(code) == [])
    }

    @Test("BusinessMath topShare: guard fraction > 0, fraction <= 1, times T(count)")
    func acceptsGuardedFractionTimesCount() {
        let code = """
        struct Concentration<T: BinaryFloatingPoint> {
            let sortedValues: [T]

            public func topShare(fraction: T) -> Int? {
                guard fraction > T.zero, fraction <= T(1) else { return nil }
                let count: T = T(sortedValues.count)
                let scaled: T = fraction * count
                let rounded = Int(scaled.rounded())
                return rounded
            }
        }
        """
        #expect(unguardedLines(code) == [])
        #expect(conversionsExamined(code) == 1)
    }

    @Test("SwiftExcelFunctions PERCENTILE: guard k >= 0, k <= 1; rank = k * Double(n - 1)")
    func acceptsPatternBoundFractionTimesCount() {
        let code = """
        func percentile(numbers: [Double], k: Double) -> Int? {
            guard k >= 0, k <= 1 else { return nil }
            let n = numbers.count
            let rank = k * Double(n - 1)
            let intPart = Int(rank)
            return intPart
        }
        """
        #expect(unguardedLines(code) == [])
    }

    @Test("BusinessMath CDS schedule: guard isFinite, >= 0, <= limit; then times T(4)")
    func acceptsBoundedValueTimesLiteral() {
        let code = """
        func periods<T: BinaryFloatingPoint>(maturity: T) -> Int {
            let maxTenorYears: T = T(1_000)
            guard maturity.isFinite, maturity >= T.zero, maturity <= maxTenorYears else {
                return 0
            }
            let quarterlyDates: T = maturity * T(4)
            let numPeriods = Int(quarterlyDates)
            return numPeriods
        }
        """
        #expect(unguardedLines(code) == [])
    }

    @Test("A product with a factor nothing has shown to be finite is not bounded")
    func flagsProductWithUnprovenFactor() {
        let code = """
        func percentile(numbers: [Double], k: Double, weight: Double) -> Int? {
            guard k >= 0, k <= 1 else { return nil }
            let rank = k * weight
            let intPart = Int(rank)
            return intPart
        }
        """
        #expect(unguardedLines(code) == [4])
    }

    @Test("A product whose fraction is bounded on one side only is not bounded")
    func flagsProductOfHalfBoundedValue() {
        let code = """
        func percentile(numbers: [Double], k: Double) -> Int? {
            guard k >= 0 else { return nil }
            let rank = k * Double(numbers.count - 1)
            let intPart = Int(rank)
            return intPart
        }
        """
        #expect(unguardedLines(code) == [4])
    }

    @Test("A quotient of bounded values is a new place for a NaN to come from")
    func flagsQuotientOfBoundedValues() {
        let code = """
        func share(part: Double, whole: Double) -> Int {
            guard part >= 0, part <= 1, whole >= 0, whole <= 1 else { return 0 }
            let ratio = part / whole
            return Int(ratio)
        }
        """
        #expect(unguardedLines(code) == [4])
    }

    @Test("A name bound twice in the body is not followed to either initialiser")
    func flagsAmbiguousLocal() {
        let code = """
        func slot(k: Double, raw: Double, flag: Bool) -> Int {
            guard k >= 0, k <= 1 else { return 0 }
            if flag {
                let rank = k * 10
                print(rank)
            }
            let rank = raw
            return Int(rank)
        }
        """
        #expect(unguardedLines(code) == [8])
    }

    @Test("A var is not what it was initialised from")
    func flagsVarLocal() {
        let code = """
        func slot(k: Double, raw: Double) -> Int {
            guard k >= 0, k <= 1 else { return 0 }
            var rank = k * 10
            rank = raw
            return Int(rank)
        }
        """
        #expect(unguardedLines(code) == [5])
    }

    @Test("BusinessMath tornadoBarWidth: positive over positive, capped at one, tested finite")
    func acceptsCappedPositiveQuotient() {
        let code = """
        internal func tornadoBarWidth(span: Double, scale: Double, limit: Int) -> Int {
            guard scale > 0, span > 0, limit > 0 else { return 0 }
            let fraction = Swift.min(span / scale, 1.0)
            guard fraction.isFinite else { return 0 }
            let columns = Int(fraction * Double(limit))
            return Swift.max(0, Swift.min(limit, columns))
        }
        """
        #expect(unguardedLines(code) == [])
        #expect(conversionsExamined(code) == 1)
    }

    @Test("The same quotient without isFinite is a NaN for infinity over infinity")
    func flagsCappedQuotientWithoutFiniteTest() {
        let code = """
        internal func tornadoBarWidth(span: Double, scale: Double, limit: Int) -> Int {
            guard scale > 0, span > 0, limit > 0 else { return 0 }
            let fraction = Swift.min(span / scale, 1.0)
            let columns = Int(fraction * Double(limit))
            return Swift.max(0, Swift.min(limit, columns))
        }
        """
        #expect(unguardedLines(code) == [4])
    }

    @Test("A quotient whose numerator may be negative has no lower bound, finite or not")
    func flagsCappedQuotientOfUnsignedNumerator() {
        let code = """
        internal func tornadoBarWidth(span: Double, scale: Double, limit: Int) -> Int {
            guard scale > 0, limit > 0 else { return 0 }
            let fraction = Swift.min(span / scale, 1.0)
            guard fraction.isFinite else { return 0 }
            let columns = Int(fraction * Double(limit))
            return Swift.max(0, Swift.min(limit, columns))
        }
        """
        #expect(unguardedLines(code) == [5])
    }
}

// MARK: - The arm a conversion sits in

// Surfaced by reading `Swift.min` as `min`: once the qualified clamp was seen as a
// floating-point value, the conversion beside it was examined for the first time, and
// the comparison that makes it safe was sitting in the ternary around it.

@Suite("fallback.int-conversion-unguarded: a condition asserts its bound inside its own arm")
struct FallbackEnclosingArmTests {

    @Test("BusinessMath expected shortfall: cappedTail > 0 ? Int(cappedTail) : 0")
    func acceptsConversionInsideTernaryArm() {
        let code = """
        func tailSize(sortedValues: [Double], tailFraction: Double) -> Int {
            let sampleCount = Double(sortedValues.count)
            let rawTail = (sampleCount * tailFraction).rounded(.up)
            let cappedTail = Swift.min(rawTail, sampleCount)
            let tailSize = cappedTail > 0 ? Int(cappedTail) : 0
            return tailSize
        }
        """
        #expect(unguardedLines(code) == [])
        #expect(conversionsExamined(code) == 1)
    }

    @Test("The same comparison around an if body")
    func acceptsConversionInsideIfBody() {
        let code = """
        func tailSize(sortedValues: [Double], tailFraction: Double) -> Int {
            let sampleCount = Double(sortedValues.count)
            let cappedTail = Swift.min(sampleCount * tailFraction, sampleCount)
            if cappedTail > 0 {
                return Int(cappedTail)
            }
            return 0
        }
        """
        #expect(unguardedLines(code) == [])
    }

    @Test("In the other arm of the ternary the comparison was false, which a NaN makes it")
    func flagsConversionInElseArmOfTernary() {
        let code = """
        func tailSize(sortedValues: [Double], tailFraction: Double) -> Int {
            let sampleCount = Double(sortedValues.count)
            let cappedTail = Swift.min(sampleCount * tailFraction, sampleCount)
            let tailSize = cappedTail > 0 ? 0 : Int(cappedTail)
            return tailSize
        }
        """
        #expect(unguardedLines(code) == [4])
    }

    @Test("In the else of the if the comparison was false")
    func flagsConversionInElseOfIf() {
        let code = """
        func tailSize(sortedValues: [Double], tailFraction: Double) -> Int {
            let sampleCount = Double(sortedValues.count)
            let cappedTail = Swift.min(sampleCount * tailFraction, sampleCount)
            if cappedTail > 0 {
                return 1
            } else {
                return Int(cappedTail)
            }
        }
        """
        #expect(unguardedLines(code) == [7])
    }

    @Test("A lower bound in the arm and no upper bound anywhere is half a range")
    func flagsArmWithOneBound() {
        let code = """
        func tailSize(tailFraction: Double) -> Int {
            return tailFraction > 0 ? Int(tailFraction) : 0
        }
        """
        #expect(unguardedLines(code) == [2])
    }

    @Test("A condition on a different value asserts nothing about this one")
    func flagsArmOfAnotherValue() {
        let code = """
        func tailSize(sortedValues: [Double], tailFraction: Double, flag: Double) -> Int {
            let sampleCount = Double(sortedValues.count)
            let cappedTail = Swift.min(sampleCount * tailFraction, sampleCount)
            return flag > 0 ? Int(cappedTail) : 0
        }
        """
        #expect(unguardedLines(code) == [4])
    }

    @Test("A condition joined with || holds when either side does")
    func flagsDisjunctionInArm() {
        let code = """
        func tailSize(sortedValues: [Double], tailFraction: Double, force: Bool) -> Int {
            let sampleCount = Double(sortedValues.count)
            let cappedTail = Swift.min(sampleCount * tailFraction, sampleCount)
            return cappedTail > 0 || force ? Int(cappedTail) : 0
        }
        """
        #expect(unguardedLines(code) == [4])
    }

    @Test("Both bounds in the arm are a range")
    func acceptsBothBoundsInArm() {
        let code = """
        func slot(position: Double) -> Int {
            return position >= 0 && position < 4_096 ? Int(position) : 0
        }
        """
        #expect(unguardedLines(code) == [])
    }
}

// MARK: - Logarithms

@Suite("fallback.int-conversion-unguarded: the logarithm of a finite positive value is small")
struct FallbackLogarithmTests {

    @Test("BusinessMath percentileColumnWidth: log10 of a finite, positive scale, floored at zero")
    func acceptsLogOfFinitePositiveValue() {
        let code = """
        func percentileColumnWidth(p5: Double, p99: Double) -> Int {
            let scale = Swift.max(p5.magnitude, p99.magnitude)
            guard scale.isFinite, scale > 0 else { return 2 }
            let integerDigits = log10(scale).rounded(.up)
            let digits = Int(Swift.max(integerDigits, 0))
            return digits + 2
        }
        """
        #expect(unguardedLines(code) == [])
        #expect(conversionsExamined(code) == 1)
    }

    @Test("Without the floor, log10(0) is -infinity")
    func flagsLogWithoutLowerBound() {
        let code = """
        func digitCount(scale: Double) -> Int {
            guard scale.isFinite, scale >= 0 else { return 2 }
            let integerDigits = log10(scale).rounded(.up)
            return Int(integerDigits)
        }
        """
        #expect(unguardedLines(code) == [4])
    }

    @Test("The logarithm of a value that may be negative is a NaN")
    func flagsLogOfUnsignedValue() {
        let code = """
        func digitCount(scale: Double) -> Int {
            guard scale.isFinite else { return 2 }
            let integerDigits = log10(scale).rounded(.up)
            return Int(Swift.max(integerDigits, 0))
        }
        """
        #expect(unguardedLines(code) == [4])
    }

    @Test("The logarithm of a value not known to be finite has no upper bound")
    func flagsLogOfPossiblyInfiniteValue() {
        let code = """
        func digitCount(scale: Double) -> Int {
            guard scale > 0 else { return 2 }
            let integerDigits = log10(scale).rounded(.up)
            return Int(Swift.max(integerDigits, 0))
        }
        """
        #expect(unguardedLines(code) == [4])
    }
}

// MARK: - Remainders

@Suite("fallback.int-conversion-unguarded: a remainder by a literal is smaller than the literal")
struct FallbackRemainderTests {

    @Test("SwiftExcelFunctions BAHTTEXT: the remainder is bounded, the quotient beside it is not")
    func acceptsRemainderAndStillFlagsQuotient() {
        let code = """
        func spell(_ value: Double) -> String {
            let totalSatang = (abs(value) * 100).rounded()
            guard totalSatang.isFinite else { return "" }
            let baht = Int(totalSatang / 100)
            let satang = Int(totalSatang.truncatingRemainder(dividingBy: 100))
            return "\\(baht) \\(satang)"
        }
        """
        // Line 4 is a real defect and stays: 1e300 is finite, and 1e298 is not an Int.
        #expect(unguardedLines(code) == [4])
        #expect(conversionsExamined(code) == 2)
    }

    @Test("A remainder of a value not tested finite is a NaN for an infinity")
    func flagsRemainderOfUntestedValue() {
        let code = """
        func satang(_ value: Double) -> Int {
            return Int(value.truncatingRemainder(dividingBy: 100))
        }
        """
        #expect(unguardedLines(code) == [2])
    }

    @Test("A remainder by a value that is not a literal has no known size")
    func flagsRemainderByVariable() {
        let code = """
        func satang(_ value: Double, modulus: Double) -> Int {
            guard value.isFinite else { return 0 }
            return Int(value.truncatingRemainder(dividingBy: modulus))
        }
        """
        #expect(unguardedLines(code) == [3])
    }
}

// MARK: - Literal-built constants

@Suite("fallback.int-conversion-unguarded: constants built from literals")
struct FallbackLiteralConstantTests {

    @Test("SwiftCLIKit LiveDashboard: dividing by a static let that is a nonzero literal")
    func acceptsDivisionByNonZeroLiteralConstant() {
        let code = """
        struct Dashboard {
            private enum Config {
                static let pollInterval: TimeInterval = 0.25
                static let updateInterval: TimeInterval = 1.0
                static let maxUpdates = 15
            }

            func run() -> Int {
                let maxPolls = Int(Double(Config.maxUpdates) * Config.updateInterval / Config.pollInterval) + 20
                return maxPolls
            }
        }
        """
        #expect(unguardedLines(code) == [])
        #expect(conversionsExamined(code) == 0)
    }

    @Test("Dividing by a static let that is literally zero is 0 / 0 waiting to happen")
    func flagsDivisionByZeroLiteralConstant() {
        let code = """
        struct Dashboard {
            private enum Config {
                static let pollInterval: TimeInterval = 0.0
                static let updateInterval: TimeInterval = 1.0
            }

            func run() -> Int {
                let maxPolls = Int(Config.updateInterval / Config.pollInterval)
                return maxPolls
            }
        }
        """
        #expect(unguardedLines(code) == [8])
    }

    @Test("Dividing by a static var is dividing by whatever it holds now")
    func flagsDivisionByStaticVar() {
        let code = """
        struct Dashboard {
            private enum Config {
                static var pollInterval: TimeInterval = 0.25
                static let updateInterval: TimeInterval = 1.0
            }

            func run() -> Int {
                let maxPolls = Int(Config.updateInterval / Config.pollInterval)
                return maxPolls
            }
        }
        """
        #expect(unguardedLines(code) == [8])
    }

    @Test("Shelfmark page geometry: a member of a static let CGSize built from literals")
    func acceptsMemberOfLiteralBuiltStruct() {
        let code = """
        import CoreGraphics

        enum LabelSheetRenderer {
            private static let pageSize = CGSize(width: 612, height: 792)
            private static let margin: CGFloat = 36

            static func columns() -> Int {
                return Int((pageSize.width - 2 * margin) / 48)
            }
        }
        """
        #expect(unguardedLines(code) == [])
    }

    @Test("A member of a struct built from a parameter is not a constant")
    func flagsMemberOfComputedStruct() {
        let code = """
        import CoreGraphics

        enum LabelSheetRenderer {
            private static let margin: CGFloat = 36

            static func columns(width: CGFloat) -> Int {
                let pageSize = CGSize(width: width, height: 792)
                return Int((pageSize.width - 2 * margin) / 48)
            }
        }
        """
        #expect(unguardedLines(code) == [8])
    }

    @Test("Shelfmark as written: the divisor comes from a computed property, and stays reported")
    func flagsDivisorFromComputedProperty() {
        let code = """
        import CoreGraphics

        enum LabelSheetRenderer {
            enum Style {
                case spine
                var cell: CGSize { CGSize(width: 36, height: 108) }
            }
            private static let pageSize = CGSize(width: 612, height: 792)
            private static let margin: CGFloat = 36
            private static let gap: CGFloat = 12

            static func columns(style: Style) -> Int {
                let cell = style.cell
                return max(1, Int((pageSize.width - 2 * margin + gap) / (cell.width + gap)))
            }
        }
        """
        #expect(unguardedLines(code) == [14])
    }
}
