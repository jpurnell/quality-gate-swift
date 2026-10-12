import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// The guard spellings the rule did not read. Fixtures are the survey sites of 2026-10-09,
// reduced: BusinessMath (CPUMatrixBackend, MultipleLinearRegression, StreamingAnomalyDetection,
// StochasticOptimizer, StreamingStatistics, VolatilitySurface, NelsonSiegel), BioFeedbackKit
// (CoreAlgorithm, FrequencyDomainMetrics), IconquerApp (ElevationGrid), sicp-swift-companion
// (Exercise_1_29).

private let divisionRule = "fp-division-unguarded"

/// The 1-based lines of every unguarded-division finding in `source`, in order.
private func divisionLines(_ source: String) -> [Int] {
    FloatingPointRules.audit(
        source: source,
        fileName: "Sources/Example/test.swift",
        options: .sources(checkDivisionGuards: true)
    ).diagnostics.filter { $0.ruleId == divisionRule }.compactMap(\.lineNumber)
}

@Suite("fp-division-unguarded: guard shapes")
struct FPDivisionGuardShapeTests {

    // MARK: - Negative-sense magnitude tests

    @Test("if abs(x) < literal { throw } covers the division after it")
    func clearsAfterThrowingMagnitudeTest() {
        let code = """
        enum MatrixError: Error { case singularMatrix }
        func solve(R: [[Double]], sums: [Double]) throws -> [Double] {
            var x = sums
            for i in 0..<sums.count {
                if abs(R[i][i]) < 1e-10 {
                    throw MatrixError.singularMatrix
                }
                var sum = 0.0
                sum += sums[i]
                x[i] = sum / R[i][i]
            }
            return x
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("The else branch of if abs(x) < literal is covered")
    func clearsElseOfMagnitudeTest() {
        let code = """
        func inflation(rSquared: Double) -> Double {
            let oneMinusR2 = 1.0 - rSquared
            var vif = 0.0
            if abs(oneMinusR2) < 1e-15 {
                vif = .infinity
            } else {
                vif = 1.0 / oneMinusR2
            }
            return vif
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("guard !(abs(x) < literal) covers the division after it")
    func clearsNegatedMagnitudeGuard() {
        let code = """
        func inverse(_ x: Double) -> Double {
            guard !(abs(x) < 1e-12) else { return 0 }
            return 1.0 / x
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("if abs(x) < literal that does not leave covers nothing")
    func flagsAfterNonExitingMagnitudeTest() {
        let code = """
        func inverse(_ x: Double) -> Double {
            if abs(x) < 1e-12 { print("small") }
            return 1.0 / x
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("The then branch of if abs(x) < literal is not covered")
    func flagsThenOfMagnitudeTest() {
        let code = """
        func inverse(_ x: Double) -> Double {
            if abs(x) < 1e-12 {
                return 1.0 / x
            }
            return 0
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("if abs(x) < 0.0 { throw } excludes nothing")
    func flagsMagnitudeTestAgainstZero() {
        let code = """
        enum E: Error { case bad }
        func inverse(_ x: Double) throws -> Double {
            if abs(x) < 0.0 { throw E.bad }
            return 1.0 / x
        }
        """
        #expect(divisionLines(code) == [4])
    }

    // MARK: - max(literal, x) thresholds

    @Test("A threshold of Swift.max(1, x) is at least one")
    func clearsMaxThreshold() {
        let code = """
        func mean(of values: [Double], minimumFinite: Int) -> Double? {
            var sum = 0.0
            var finiteCount = 0
            for value in values where value.isFinite {
                sum += value
                finiteCount += 1
            }
            guard finiteCount >= Swift.max(1, minimumFinite) else {
                return nil
            }
            return sum / Double(finiteCount)
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A threshold of Swift.max(0, x) or Swift.min(1, x) excludes nothing")
    func flagsWeakThresholds() {
        let code = """
        func mean(sum: Double, finiteCount: Int, other: Int, minimumFinite: Int) -> Double? {
            guard finiteCount >= Swift.max(0, minimumFinite) else { return nil }
            guard other >= Swift.min(1, minimumFinite) else { return nil }
            return sum / Double(finiteCount) + sum / Double(other)
        }
        """
        #expect(divisionLines(code) == [4, 4])
    }

    // MARK: - isEmpty through a count-preserving let

    @Test("A guard on xs.isEmpty covers the count of xs.map")
    func clearsCountOfMappedCollection() {
        let code = """
        func profile(for coordinates: [(Double, Double)]) -> Float {
            guard !coordinates.isEmpty else {
                return 0
            }
            let samples = coordinates.map { Float($0.0 + $0.1) }
            let sum = samples.reduce(0, +)
            return sum / Float(samples.count)
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A count is carried through sorted() and Array(_:) as well")
    func clearsCountOfSortedAndCopied() {
        let code = """
        func median(of values: [Double], sum: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let ordered = values.sorted()
            let copy = Array(ordered)
            return 100.0 * sum / Double(ordered.count) + 100.0 * sum / Double(copy.count)
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A guard on xs.isEmpty does not cover the count of xs.filter")
    func flagsCountOfFilteredCollection() {
        let code = """
        func profile(for coordinates: [Float]) -> Float {
            guard !coordinates.isEmpty else { return 0 }
            let samples = coordinates.filter { $0 > 0 }
            let sum = samples.reduce(0, +)
            return sum / Float(samples.count)
        }
        """
        #expect(divisionLines(code) == [5])
    }

    @Test("A var bound to xs.map is not the same count")
    func flagsCountOfMappedVar() {
        let code = """
        func profile(for coordinates: [Float]) -> Float {
            guard !coordinates.isEmpty else { return 0 }
            var samples = coordinates.map { $0 * 2 }
            samples.removeAll()
            return 1.0 / Float(samples.count)
        }
        """
        #expect(divisionLines(code) == [5])
    }

    // MARK: - Loop bounds

    @Test("The bound of a 0..<n loop is nonzero inside the loop")
    func clearsLoopBoundInsideLoop() {
        let code = """
        func centre(_ simplex: [[Double]], n: Int) -> [Double] {
            var centroid = [Double](repeating: 0.0, count: n)
            for j in 0..<n {
                centroid[j] /= Double(n)
            }
            return centroid
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("The bound of a loop is not known after the loop, nor for a closed range from zero")
    func flagsLoopBoundOutsideLoop() {
        let code = """
        func centre(total: Double, n: Int, m: Int) -> Double {
            var out = 0.0
            for _ in 0..<n { out += 1 }
            out += total / Double(n)
            for _ in 0...m { out += total / Double(m) }
            return out
        }
        """
        #expect(divisionLines(code) == [4, 5])
    }

    @Test("A non-negative loop index plus a positive literal is nonzero")
    func clearsLoopIndexPlusOne() {
        let code = """
        func runningMean(_ values: [Double]) -> Double {
            var runningMean = 0.0
            for (i, value) in values.enumerated() {
                let delta = value - runningMean
                runningMean += delta / Double(i + 1)
            }
            for i in 0..<values.count {
                runningMean += values[i] / Double(i + 1)
            }
            return runningMean
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A loop index alone, or one that starts below zero, still fires")
    func flagsLoopIndexAlone() {
        let code = """
        func runningMean(_ values: [Double], n: Int) -> Double {
            var runningMean = 0.0
            for (i, value) in values.enumerated() {
                runningMean += value / Double(i)
            }
            for i in -1..<n {
                runningMean += 1.0 / Double(i + 1)
            }
            return runningMean
        }
        """
        #expect(divisionLines(code) == [4, 7])
    }

    // MARK: - A Bool predicate declared in this file

    @Test("A guard on a predicate of a type in this file asserts the comparisons it guards")
    func clearsThroughPredicate() {
        let code = """
        struct BondMarketData {
            let maturity: Double
            let frequency: Int
            let faceValue: Double
            var isSchedulable: Bool {
                guard maturity.isFinite, maturity > 0, frequency >= 1 else { return false }
                let payments = maturity * Double(frequency)
                return payments.isFinite
            }
        }
        func price(bond: BondMarketData) -> Double {
            guard bond.isSchedulable else { return Double.nan }
            let periodsPerYear = Double(bond.frequency)
            return bond.faceValue / periodsPerYear
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A predicate that does not test the divisor against a positive literal covers nothing")
    func flagsThroughWeakPredicate() {
        let code = """
        struct BondMarketData {
            let frequency: Int
            let faceValue: Double
            var isSchedulable: Bool {
                guard frequency >= 0 else { return false }
                return true
            }
        }
        func price(bond: BondMarketData) -> Double {
            guard bond.isSchedulable else { return Double.nan }
            let periodsPerYear = Double(bond.frequency)
            return bond.faceValue / periodsPerYear
        }
        """
        #expect(divisionLines(code) == [12])
    }

    @Test("A predicate whose guard returns true on failure covers nothing")
    func flagsThroughInvertedPredicate() {
        let code = """
        struct BondMarketData {
            let frequency: Int
            let faceValue: Double
            var isDegenerate: Bool {
                guard frequency >= 1 else { return true }
                return false
            }
        }
        func price(bond: BondMarketData) -> Double {
            guard bond.isDegenerate else { return Double.nan }
            let periodsPerYear = Double(bond.frequency)
            return bond.faceValue / periodsPerYear
        }
        """
        #expect(divisionLines(code) == [12])
    }

    @Test("A predicate on a value whose type this file does not declare covers nothing")
    func flagsThroughForeignPredicate() {
        let code = """
        struct BondMarketData {
            let frequency: Int
            var isSchedulable: Bool {
                guard frequency >= 1 else { return false }
                return true
            }
        }
        func price(bond: ForeignBond) -> Double {
            guard bond.isSchedulable else { return Double.nan }
            let periodsPerYear = Double(bond.frequency)
            return 100.0 / periodsPerYear
        }
        """
        #expect(divisionLines(code) == [11])
    }

    // MARK: - positive literal + non-negative term

    @Test("1.0 + exp(x) is at least one")
    func clearsOnePlusExp() {
        let code = """
        func sigmoid(_ raw: Double) -> Double {
            return 1.0 / (1.0 + exp(-raw))
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("0.0 + exp(x), 1.0 - exp(x) and 1.0 + log(x) still fire")
    func flagsWeakerSums() {
        let code = """
        func broken(_ raw: Double) -> Double {
            let a = 1.0 / (0.0 + exp(-raw))
            let b = 1.0 / (1.0 - exp(-raw))
            let c = 1.0 / (1.0 + log(raw))
            return a + b + c
        }
        """
        #expect(divisionLines(code) == [2, 3, 4])
    }

    // MARK: - A ternary of covered values

    @Test("A let bound to a ternary whose branches are both covered is covered")
    func clearsTernaryOfGuardedValues() {
        let code = """
        func simpson(a: Double, b: Double, n: Int) -> Double {
            guard n > 0 else { return 0 }
            let evenN = n.isMultiple(of: 2) ? n : n + 1
            let h = (b - a) / Double(evenN)
            return h
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A ternary with one branch that can be zero still fires")
    func flagsTernaryWithZeroBranch() {
        let code = """
        func simpson(a: Double, b: Double, n: Int) -> Double {
            guard n > 0 else { return 0 }
            let evenN = n.isMultiple(of: 2) ? n : n - 1
            let h = (b - a) / Double(evenN)
            return h
        }
        """
        #expect(divisionLines(code) == [4])
    }

    // MARK: - Aliases are positional

    @Test("A later let of the same name does not take an earlier alias's guard away")
    func clearsEarlierAliasDespiteLaterRedeclaration() {
        let code = """
        func spread(_ xs: [Double], _ ys: [Double]) -> Double {
            let wasEmpty = xs.isEmpty
            let n = xs.count
            let mean = xs.reduce(0.0, +) / Double(n)
            let other: Double = {
                let n = ys.count
                return 1.0 / Double(n)
            }()
            return wasEmpty ? 0 : mean + other
        }
        """
        #expect(divisionLines(code) == [7])
    }

    @Test("A later alias does not lend its guard to an earlier let of the same name")
    func flagsEarlierAliasOfUnguardedValue() {
        let code = """
        func spread(_ xs: [Double], _ ys: [Double]) -> Double {
            guard xs.count >= 2 else { return 0 }
            let first: Double = {
                let n = ys.count
                return 1.0 / Double(n)
            }()
            let n = xs.count
            return first + xs.reduce(0.0, +) / Double(n)
        }
        """
        #expect(divisionLines(code) == [5])
    }
}
