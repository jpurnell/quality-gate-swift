import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// The first fixtures for these rules were written from the proposal's
// description of each defect, and every one of them passed while the rules
// missed every real site they were named after. These are the real sites, from
// BusinessMath at `464cf939`, reduced only by deleting what is not involved.

private func findings(_ source: String, rule: String) -> [Diagnostic] {
    FallbackRules.audit(source: source, fileName: "Sources/BusinessMath/Site.swift")
        .diagnostics
        .filter { $0.ruleId == rule }
}

@Suite("fallback: the real sites, as written")
struct FallbackRealShapeTests {

    // kendallW.swift:306-309. `s` is a `var` that starts at `T(0)`; `denom` is a
    // product of converted integers.
    @Test("Kendall's W: an accumulator started from T(0), divided, clamped")
    func kendallWAsWritten() {
        let code = """
        public func concordanceAnalysisFromRankSums<T: Real & Sendable>(
            rankSums: [T], judges: Int, items: Int
        ) -> T {
            let m = T(judges)
            let n = T(items)
            var s = T(0)
            for sum in rankSums {
                s += sum * sum
            }
            let denom = m * m * (n * n * n - n)
            let w: T
            if abs(denom) > T.ulpOfOne {
                w = max(T(0), min(T(1), (T(12) * s) / denom))
            } else {
                w = T(0)
            }
            return w
        }
        """
        let found = findings(code, rule: FallbackRuleID.clampAbsorbsNaN)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 13)
    }

    // StreamingForecasting.swift:843-873.
    @Test("Trend confidence: sums from reduce(0.0), a quotient, a clamp")
    func trendConfidenceAsWritten() {
        let code = """
        func confidence(buffer: [Double]) -> Double {
            let n = Double(buffer.count)
            let sumY = buffer.reduce(0.0, +)
            let meanY = sumY / n
            let ssTotal = buffer.reduce(0.0) { $0 + pow($1 - meanY, 2) }
            let ssResidual = buffer.reduce(0.0) { $0 + pow($1 - meanY, 2) }
            let rSquared = 1.0 - (ssResidual / ssTotal)
            return Swift.max(0, Swift.min(1, rSquared))
        }
        """
        let found = findings(code, rule: FallbackRuleID.clampAbsorbsNaN)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 8)
    }

    // StreamingForecasting.swift:849-868.
    @Test("detectTrend: a slope that is a quotient of sums, sorted three ways")
    func detectTrendAsWritten() {
        let code = """
        func direction(buffer: [Double]) -> Int {
            let n = Double(buffer.count)
            let sumX = (0..<buffer.count).reduce(0.0) { $0 + Double($1) }
            let sumY = buffer.reduce(0.0, +)
            let slope = (n * sumY - sumX * sumY) / (n * sumX - sumX * sumX)
            if abs(slope) < 0.1 {
                return 0
            } else if slope > 0 {
                return 1
            } else {
                return -1
            }
        }
        """
        let found = findings(code, rule: FallbackRuleID.classificationOmitsNaN)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 6)
    }

    // NPV.swift:300-313.
    @Test("profitabilityIndex: the flow comes out of enumerated()")
    func profitabilityIndexAsWritten() {
        let code = """
        public func profitabilityIndex<T: Real>(rate: T, cashFlows: [T]) -> T {
            var pvPositive = T.zero
            var pvNegative = T.zero
            for (period, flow) in cashFlows.enumerated() {
                let discountFactor = T.pow(T(1) + rate, T(period))
                let presentValue = flow / discountFactor
                if flow > T.zero {
                    pvPositive = pvPositive + presentValue
                } else if flow < T.zero {
                    pvNegative = pvNegative + presentValue
                }
            }
            return pvPositive / pvNegative
        }
        """
        let found = findings(code, rule: FallbackRuleID.classificationOmitsNaN)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 7)
    }

    @Test("An element read by subscript is as floating-point as its collection")
    func subscriptOfCollection() {
        let code = """
        func bucket(values: [Double], index: Int) -> Int {
            return Int(values[index])
        }
        """
        let found = findings(code, rule: FallbackRuleID.intConversionUnguarded)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 2)
    }
}

// MARK: - Floating-point is not the same as able to be NaN

@Suite("fallback: a value can be floating-point and still be known")
struct FallbackFiniteValueTests {

    @Test("A let converted from an integer stays finite through a product")
    func finiteLetThroughProduct() {
        let code = """
        func cutoff(count: Int) -> Int {
            let n = Double(count)
            let scaled = n * 0.95
            return Int(scaled)
        }
        """
        #expect(findings(code, rule: FallbackRuleID.intConversionUnguarded).isEmpty)
    }

    @Test("A quotient of finite values can be NaN: 0 / 0")
    func quotientOfFiniteValues() {
        let code = """
        func average(total: Int, count: Int) -> Int {
            let mean = Double(total) / Double(count)
            return Int(mean)
        }
        """
        let found = findings(code, rule: FallbackRuleID.intConversionUnguarded)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 3)
    }

    @Test("A quotient converted where it is computed has no name to check")
    func quotientConvertedDirectly() {
        let code = """
        func average(total: Int, count: Int) -> Int {
            return Int(Double(total) / Double(count))
        }
        """
        let found = findings(code, rule: FallbackRuleID.intConversionUnguarded)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("has no name") == true)
    }

    @Test("A quotient bound to a local and guarded: no finding")
    func quotientGuarded() {
        let code = """
        func average(total: Int, count: Int) -> Int {
            let mean = Double(total) / Double(count)
            guard abs(mean) < 1e15 else { return 0 }
            return Int(mean)
        }
        """
        #expect(findings(code, rule: FallbackRuleID.intConversionUnguarded).isEmpty)
    }

    @Test("A var started from a literal is floating-point, and not where it started")
    func accumulatorIsNotConstant() {
        let code = """
        func total(values: [Double]) -> Int {
            var sum = 0.0
            for value in values { sum += value }
            return Int(sum)
        }
        """
        let found = findings(code, rule: FallbackRuleID.intConversionUnguarded)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 4)
    }
}

// MARK: - What the second measured run got wrong

@Suite("fallback: corrections from the second measured run")
struct FallbackSecondRunTests {

    // BusinessMath `distributionDiscreteUniform.swift:100`. The file declares
    // `count: Double`, and `values.count` is `Array.count`.
    @Test("values.count is the array's, whatever else in the file is called count")
    func standardLibraryMemberIsNotTheFilesMember() {
        let code = """
        struct DiscreteUniform {
            let values: [Double]
            let count: Double
            func quantile(_ p: Double) -> Int {
                guard p > 0, p < 1 else { return 0 }
                let scaled: Double = p * count
                let index = Int(exactly: scaled.rounded(.up)) ?? 0
                return Swift.min(Swift.max(index, 0), values.count - 1)
            }
        }
        """
        #expect(findings(code, rule: FallbackRuleID.clampAbsorbsNaN).isEmpty)
    }

    // This repository, `DashboardApp.swift:169`.
    @Test("A quotient of integers whose divisor is tested above zero is a number")
    func quotientWithCheckedDivisor() {
        let code = """
        func percent(offset: Int, maxScroll: Int) -> Int {
            if maxScroll > 0 {
                return Int((Double(offset) / Double(maxScroll) * 100).rounded())
            }
            return 0
        }
        """
        #expect(findings(code, rule: FallbackRuleID.intConversionUnguarded).isEmpty)
    }

    // BusinessMath `CommandLineVisualization.swift`.
    @Test("A divisor tested by the ternary that guards the quotient")
    func quotientGuardedByTernary() {
        let code = """
        func barWidth(count: Int, maxCount: Int, width: Int) -> Int {
            return maxCount > 0 ? Int(Double(count) / Double(maxCount) * Double(width)) : 0
        }
        """
        #expect(findings(code, rule: FallbackRuleID.intConversionUnguarded).isEmpty)
    }

    // This repository, `StatusValidator.swift:87`.
    @Test("A divisor floored at a non-zero literal cannot be zero")
    func divisorFlooredAtLiteral() {
        let code = """
        func drift(claimed: Int, actual: Int) -> Int {
            let difference = abs(claimed - actual)
            let percent = Double(difference) / max(Double(claimed), 1.0) * 100.0
            return Int(percent)
        }
        """
        #expect(findings(code, rule: FallbackRuleID.intConversionUnguarded).isEmpty)
    }

    @Test("A divisor that is a product of literals")
    func divisorIsLiteralProduct() {
        let code = """
        func years(seconds: Int) -> Int {
            return Int(Double(seconds) / (365.25 * 24 * 3600))
        }
        """
        #expect(findings(code, rule: FallbackRuleID.intConversionUnguarded).isEmpty)
    }

    @Test("A checked divisor does not clean the dividend")
    func checkedDivisorUncheckedDividend() {
        let code = """
        func share(amount: Double, total: Int) -> Int {
            guard total > 0 else { return 0 }
            return Int(amount / Double(total))
        }
        """
        let found = findings(code, rule: FallbackRuleID.intConversionUnguarded)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("'amount'") == true)
    }

    // This repository, `DashboardRenderer.swift:240`. The first evaluation
    // called this finite, because it ignored the operand it knew nothing about.
    @Test("A value of unknown origin in floating-point arithmetic is not known to be a number")
    func unknownOperandInFloatingPointArithmetic() {
        let code = """
        func top(values: [Double]) -> Int {
            let maxVal = values.max() ?? 1.0
            return Int(maxVal)
        }
        """
        let found = findings(code, rule: FallbackRuleID.intConversionUnguarded)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 3)
    }

    @Test("An integer of unknown origin plus an integer literal is still an integer")
    func unknownOperandInIntegerArithmetic() {
        let code = """
        func next() -> Int {
            return Int(somethingElsewhere + 1)
        }
        """
        #expect(findings(code, rule: FallbackRuleID.intConversionUnguarded).isEmpty)
    }
}
