import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

/// The lines one `fallback` rule reports in `source`.
private func lines(
    _ ruleId: String,
    in source: String,
    filePath: String = "Sources/TVM/IRR.swift"
) -> [Int] {
    FallbackRules.audit(source: source, fileName: filePath)
        .diagnostics
        .filter { $0.ruleId == ruleId }
        .compactMap(\.lineNumber)
}

private func classificationLines(_ source: String) -> [Int] {
    lines(FallbackRuleID.classificationOmitsNaN, in: source)
}

private func clampLines(_ source: String) -> [Int] {
    lines(FallbackRuleID.clampAbsorbsNaN, in: source)
}

// Fixtures are real sites from the 2026-10-09 portfolio survey, reduced. Each accepted
// shape is paired with the nearest shape in which a NaN is still answered for.

// MARK: - Collections tested as a whole

@Suite("fallback: a collection tested as a whole answers for its elements")
struct FallbackCollectionProofTests {

    @Test("BusinessMath MIRR: guard cashFlows.allSatisfy({ !$0.isNaN }) above the loop")
    func acceptsAllSatisfyNotNaNOverEnumerated() {
        let code = """
        func mirr<T: BinaryFloatingPoint>(cashFlows: [T]) -> T? {
            guard cashFlows.allSatisfy({ !$0.isNaN }) else {
                return nil
            }
            var pvNegative = T.zero
            var fvPositive = T.zero
            for (period, cashFlow) in cashFlows.enumerated() {
                if cashFlow < T.zero {
                    pvNegative = pvNegative + cashFlow
                } else if cashFlow > T.zero {
                    fvPositive = fvPositive + cashFlow + T(period)
                }
            }
            return pvNegative + fvPositive
        }
        """
        #expect(classificationLines(code) == [])
    }

    @Test("allSatisfy { $0.isFinite }, a plain for-in, and a key path all say the same thing")
    func acceptsOtherSpellings() {
        let code = """
        func signs(values: [Double], others: [Double]) -> Int {
            guard values.allSatisfy({ $0.isFinite }), others.allSatisfy(\\.isFinite) else { return 0 }
            var total = 0
            for value in values {
                if value < 0 {
                    total -= 1
                } else if value > 0 {
                    total += 1
                }
            }
            for other in others {
                if other < 0 {
                    total -= 1
                } else if other > 0 {
                    total += 1
                }
            }
            return total
        }
        """
        #expect(classificationLines(code) == [])
    }

    @Test("A filtered copy holds only what passed the filter")
    func acceptsFilteredCopy() {
        let code = """
        func signs(values: [Double]) -> Int {
            let clean = values.filter { $0.isFinite }
            var total = 0
            for value in clean {
                if value < 0.0 {
                    total -= 1
                } else if value > 0.0 {
                    total += 1
                }
            }
            return total
        }
        """
        #expect(classificationLines(code) == [])
    }

    @Test("A copy filtered on something else still holds the NaNs")
    func flagsCopyFilteredOnAnotherProperty() {
        let code = """
        func signs(values: [Double]) -> Int {
            let clean = values.filter { !$0.isZero }
            var total = 0
            for value in clean {
                if value < 0.0 {
                    total -= 1
                } else if value > 0.0 {
                    total += 1
                }
            }
            return total
        }
        """
        #expect(classificationLines(code) == [5])
    }

    @Test("allSatisfy on a different collection says nothing about this one")
    func flagsAllSatisfyOnAnotherCollection() {
        let code = """
        func mirr<T: BinaryFloatingPoint>(cashFlows: [T], rates: [T]) -> T? {
            guard rates.allSatisfy({ !$0.isNaN }) else {
                return nil
            }
            var pvNegative = T.zero
            var fvPositive = T.zero
            for (period, cashFlow) in cashFlows.enumerated() {
                if cashFlow < T.zero {
                    pvNegative = pvNegative + cashFlow
                } else if cashFlow > T.zero {
                    fvPositive = fvPositive + cashFlow + T(period)
                }
            }
            return pvNegative + fvPositive
        }
        """
        #expect(classificationLines(code) == [8])
    }

    @Test("allSatisfy that tests something other than being a number proves nothing here")
    func flagsAllSatisfyOfAnotherProperty() {
        let code = """
        func signs(values: [Double]) -> Int {
            guard values.allSatisfy({ $0.isZero }) else { return 0 }
            var total = 0
            for value in values {
                if value < 0 {
                    total -= 1
                } else if value > 0 {
                    total += 1
                }
            }
            return total
        }
        """
        #expect(classificationLines(code) == [5])
    }

    @Test("allSatisfy computed but not asserted lets the loop run anyway")
    func flagsUnassertedAllSatisfy() {
        let code = """
        func signs(values: [Double]) -> Int {
            let clean = values.allSatisfy({ $0.isFinite })
            print(clean)
            var total = 0
            for value in values {
                if value < 0 {
                    total -= 1
                } else if value > 0 {
                    total += 1
                }
            }
            return total
        }
        """
        #expect(classificationLines(code) == [6])
    }

    @Test("A collection tested after the loop was not tested before it")
    func flagsAllSatisfyAfterTheLoop() {
        let code = """
        func signs(values: [Double]) -> Int {
            var total = 0
            for value in values {
                if value < 0 {
                    total -= 1
                } else if value > 0 {
                    total += 1
                }
            }
            guard values.allSatisfy({ $0.isFinite }) else { return 0 }
            return total
        }
        """
        #expect(classificationLines(code) == [4])
    }

    @Test("Finite elements are still unbounded: the conversion needs a magnitude")
    func allSatisfyFiniteDoesNotBoundAConversion() {
        let code = """
        func years(tenors: [Double]) -> [Int] {
            guard tenors.allSatisfy({ $0.isFinite }) else { return [] }
            var result: [Int] = []
            for tenor in tenors {
                result.append(Int(tenor))
            }
            return result
        }
        """
        #expect(lines(FallbackRuleID.intConversionUnguarded, in: code) == [5])
    }
}

// MARK: - A guard on a derived local

@Suite("fallback: a guard on a value computed from the operand excludes a NaN in the operand")
struct FallbackDerivedLocalTests {

    @Test("BusinessMath etsSearchCoordinate: span = upper - lower; guard span > 0")
    func acceptsGuardOnDifference() {
        let code = """
        func etsSearchCoordinate(_ parameter: Double, lower: Double, upper: Double) -> Double {
            let span = upper - lower
            guard span > 0 else { return 0 }
            let clamped = Swift.min(Swift.max(parameter, lower), upper)
            return clamped - lower
        }
        """
        #expect(clampLines(code) == [])
    }

    @Test("SwiftCLIKit InlineSparkline: range = hi - lo; guard range > T.zero, clamp in a closure")
    func acceptsGuardOnDifferenceAcrossClosure() {
        let code = """
        func mapToBlocks<T: BinaryFloatingPoint>(_ values: [T], lo: T, hi: T) -> [T] {
            let range = hi - lo
            guard range > T.zero else {
                return values
            }
            return values.map { value in
                let clamped = Swift.min(Swift.max(value, lo), hi)
                return clamped
            }
        }
        """
        #expect(clampLines(code) == [])
    }

    @Test("The same clamp with no guard on the span returns the value for a NaN bound")
    func flagsClampWithoutGuard() {
        let code = """
        func etsSearchCoordinate(_ parameter: Double, lower: Double, upper: Double) -> Double {
            let span = upper - lower
            let clamped = Swift.min(Swift.max(parameter, lower), upper)
            return clamped - lower + span
        }
        """
        #expect(clampLines(code) == [3])
    }

    @Test("A guard on a local that does not involve the operand excludes nothing")
    func flagsGuardOnUnrelatedLocal() {
        let code = """
        func etsSearchCoordinate(_ parameter: Double, lower: Double, upper: Double, width: Double) -> Double {
            let span = width - 1
            guard span > 0 else { return 0 }
            let clamped = Swift.min(Swift.max(parameter, lower), upper)
            return clamped - lower
        }
        """
        #expect(clampLines(code) == [4])
    }

    @Test("A local built with min can swallow a NaN, so a guard on it proves nothing")
    func flagsGuardOnAbsorbingLocal() {
        let code = """
        func etsSearchCoordinate(_ parameter: Double, lower: Double, upper: Double) -> Double {
            let span = min(1.0, upper - lower)
            guard span > 0 else { return 0 }
            let clamped = Swift.min(Swift.max(parameter, lower), upper)
            return clamped - lower
        }
        """
        #expect(clampLines(code) == [4])
    }

    @Test("A derived local that is compared but not in a guard asserts nothing")
    func flagsUnassertedDerivedLocal() {
        let code = """
        func etsSearchCoordinate(_ parameter: Double, lower: Double, upper: Double) -> Double {
            let span = upper - lower
            if span > 0 { print("ok") }
            let clamped = Swift.min(Swift.max(parameter, lower), upper)
            return clamped - lower
        }
        """
        #expect(clampLines(code) == [4])
    }

    @Test("A guard that only asks whether the span is zero is passed by a NaN")
    func flagsNonZeroOnlyGuard() {
        let code = """
        func etsSearchCoordinate(_ parameter: Double, lower: Double, upper: Double) -> Double {
            let span = upper - lower
            guard span != 0 else { return 0 }
            let clamped = Swift.min(Swift.max(parameter, lower), upper)
            return clamped - lower
        }
        """
        #expect(clampLines(code) == [4])
    }
}

// MARK: - An enclosing isInfinite arm

@Suite("fallback.classification-omits-nan: inside an isInfinite arm the value is not a NaN")
struct FallbackInfiniteArmTests {

    @Test("A chain inside `if x.isInfinite` sorts the two infinities")
    func acceptsChainInsideInfiniteArm() {
        let code = """
        func describe(_ value: Double) -> String {
            if value.isInfinite {
                if value > 0 {
                    return "∞"
                } else if value < 0 {
                    return "-∞"
                }
            }
            return "number"
        }
        """
        #expect(classificationLines(code) == [])
    }

    @Test("A chain in the else of an isInfinite test still receives a NaN")
    func flagsChainInElseOfInfiniteTest() {
        let code = """
        func describe(_ value: Double) -> String {
            if value.isInfinite {
                return "∞"
            } else {
                if value > 0 {
                    return "positive"
                } else if value < 0 {
                    return "negative"
                }
            }
            return "zero"
        }
        """
        #expect(classificationLines(code) == [5])
    }

    @Test("An isInfinite arm for a different value says nothing about this one")
    func flagsInfiniteArmOfAnotherValue() {
        let code = """
        func describe(_ value: Double, other: Double) -> String {
            if other.isInfinite {
                if value > 0 {
                    return "positive"
                } else if value < 0 {
                    return "negative"
                }
            }
            return "zero"
        }
        """
        #expect(classificationLines(code) == [3])
    }
}

// MARK: - A trailing else that yields the subject

@Suite("fallback.classification-omits-nan: a trailing else that yields the subject propagates a NaN")
struct FallbackElseYieldsSubjectTests {

    @Test("BusinessMath Tukey HSD: a clamp ladder whose else assigns the value itself")
    func acceptsElseAssigningTheSubject() {
        let code = """
        func clampProbability<T: BinaryFloatingPoint>(_ cdfValue: T) -> T {
            let p = T(1) - cdfValue
            let clampedP: T
            if p < T.zero {
                clampedP = T.zero
            } else if p > T(1) {
                clampedP = T(1)
            } else {
                clampedP = p
            }
            return clampedP
        }
        """
        #expect(classificationLines(code) == [])
    }

    @Test("BusinessMath collar payoff: the else returns a value computed from the subject")
    func acceptsElseReturningArithmeticOnTheSubject() {
        let code = """
        struct Collar<T: BinaryFloatingPoint> {
            let shortPutStrike: T
            let longPutStrike: T
            let shortCallStrike: T

            public func payoff(spotPrice: T) -> T {
                if spotPrice < shortPutStrike {
                    return longPutStrike - shortPutStrike
                } else if spotPrice < longPutStrike {
                    return longPutStrike - spotPrice
                } else if spotPrice <= shortCallStrike {
                    return T.zero
                } else {
                    // Above the short call.
                    return -(spotPrice - shortCallStrike)
                }
            }
        }
        """
        #expect(classificationLines(code) == [])
    }

    @Test("An else that returns a literal answers for the NaN")
    func flagsElseReturningLiteral() {
        let code = """
        func clampProbability<T: BinaryFloatingPoint>(_ p: T) -> T {
            let clampedP: T
            if p < T.zero {
                clampedP = T.zero
            } else if p > T(1) {
                clampedP = T(1)
            } else {
                clampedP = T(1) / T(2)
            }
            return clampedP
        }
        """
        #expect(classificationLines(code) == [3])
    }

    @Test("An else that yields a different value answers for the NaN")
    func flagsElseYieldingAnotherValue() {
        let code = """
        func pick(_ p: Double, fallback: Double) -> Double {
            if p < 0 {
                return 0
            } else if p > 1 {
                return 1
            } else {
                return fallback
            }
        }
        """
        #expect(classificationLines(code) == [2])
    }

    @Test("An else that passes the subject through min can swallow the NaN")
    func flagsElseYieldingThroughMin() {
        let code = """
        func pick(_ p: Double) -> Double {
            if p < 0 {
                return 0
            } else if p > 1 {
                return 1
            } else {
                return min(0.5, p)
            }
        }
        """
        #expect(classificationLines(code) == [2])
    }

    @Test("An else that compares the subject yields a Bool, not the NaN")
    func flagsElseYieldingComparison() {
        let code = """
        func inBand(_ p: Double) -> Bool {
            if p < 0 {
                return false
            } else if p > 1 {
                return false
            } else {
                return p >= 0
            }
        }
        """
        #expect(classificationLines(code) == [2])
    }

    @Test("No trailing else: the NaN takes no arm, whatever the arms yield")
    func flagsChainWithoutElse() {
        let code = """
        func total(_ p: Double) -> Double {
            var sum = 0.0
            if p < 0 {
                sum = p
            } else if p > 1 {
                sum = p
            }
            return sum
        }
        """
        #expect(classificationLines(code) == [3])
    }
}
