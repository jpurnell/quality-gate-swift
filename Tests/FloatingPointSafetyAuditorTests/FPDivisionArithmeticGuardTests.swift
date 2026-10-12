import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// An arithmetic divisor under a guard that dominates it. Fixtures are the survey sites of
// 2026-10-09, reduced: BusinessMath (SensitivityAnalysis, PortfolioOptimizer, AdaptiveProgress,
// MonteCarloEngine, StreamingStatistics, StreamingAnomalyDetection, Stationarity, FFTBackend),
// BioFeedbackKit (FrequencyDomainMetrics), BusinessMath-UI (TimeControlsView),
// IconquerApp (GeoStore).

private let divisionRule = "fp-division-unguarded"

/// The 1-based lines of every unguarded-division finding in `source`, in order.
private func divisionLines(_ source: String) -> [Int] {
    FloatingPointRules.audit(
        source: source,
        fileName: "Sources/Example/test.swift",
        options: .sources(checkDivisionGuards: true)
    ).diagnostics.filter { $0.ruleId == divisionRule }.compactMap(\.lineNumber)
}

@Suite("fp-division-unguarded: an arithmetic divisor under a dominating guard")
struct FPDivisionArithmeticGuardTests {

    // MARK: - n - k

    @Test("guard n > 1 covers a divisor of n - 1")
    func clearsMinusOneUnderStrictGuard() {
        let code = """
        func steps(from: Double, to: Double, steps: Int) -> Double {
            guard steps > 1 else {
                return from
            }
            let stepSize = (to - from) / Double(steps - 1)
            return stepSize
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("guard n >= 2 covers a divisor of n - 1")
    func clearsMinusOneUnderInclusiveGuard() {
        let code = """
        func variance(_ values: [Double]) -> Double {
            let n = values.count
            guard n >= 2 else { return 0 }
            return values.reduce(0.0) { $0 + $1 * $1 } / Double(n - 1)
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("guard n > 1 does not cover a divisor of n - 2")
    func flagsMinusTwoUnderGuardOfOne() {
        let code = """
        func steps(from: Double, to: Double, steps: Int) -> Double {
            guard steps > 1 else { return from }
            return (to - from) / Double(steps - 2)
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("guard n >= 1 does not cover a divisor of n - 1")
    func flagsMinusOneUnderInclusiveGuardOfOne() {
        let code = """
        func steps(from: Double, to: Double, steps: Int) -> Double {
            guard steps >= 1 else { return from }
            return (to - from) / Double(steps - 1)
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A guard on a member count covers count - 1")
    func clearsMemberCountMinusOne() {
        let code = """
        struct Window {
            var buffer: [Double] = []
            func variance(mean: Double) -> Double {
                guard buffer.count >= 2 else { return .nan }
                return buffer.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(buffer.count - 1)
            }
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A guard on a member reached through a value covers member - 1")
    func clearsMemberPathMinusOne() {
        let code = """
        struct TimeState { var totalSteps: Int; var currentTimeIndex: Int }
        func progress(state: TimeState) -> CGFloat {
            guard state.totalSteps > 1 else { return 0 }
            return CGFloat(state.currentTimeIndex) / max(CGFloat(state.totalSteps - 1), .leastNonzeroMagnitude)
        }
        """
        #expect(divisionLines(code) == [])
    }

    // MARK: - Dominance

    @Test("An if branch covers a divisor inside it")
    func clearsInsideIfBranch() {
        let code = """
        func variance(m2: Double, count: Int) -> Double {
            let variance: Double
            if count > 1 {
                variance = m2 / Double(count - 1)
            } else {
                variance = .nan
            }
            return variance
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("An if branch does not cover its else branch")
    func flagsInsideElseBranch() {
        let code = """
        func variance(m2: Double, count: Int) -> Double {
            let variance: Double
            if count > 1 {
                variance = .nan
            } else {
                variance = m2 / Double(count - 1)
            }
            return variance
        }
        """
        #expect(divisionLines(code) == [6])
    }

    @Test("An if that does not leave does not cover what follows it")
    func flagsAfterNonExitingIf() {
        let code = """
        func variance(m2: Double, count: Int) -> Double {
            if count > 1 { print("enough") }
            return m2 / Double(count - 1)
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("An early return on the opposite test covers what follows it")
    func clearsAfterEarlyReturn() {
        let code = """
        func variance(m2: Double, count: Int) -> Double {
            if count <= 1 { return .nan }
            return m2 / Double(count - 1)
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A guard on the integer covers its converted alias minus a literal")
    func clearsConvertedAliasMinusLiteral() {
        let code = """
        func variance(deviations: [Double], observationCount: Int) -> Double {
            var sumSquaredDeviations = 0.0
            for deviation in deviations { sumSquaredDeviations += deviation * deviation }
            let m = Double(observationCount)
            let variance: Double
            if observationCount > 1 {
                variance = sumSquaredDeviations / (m - 1.0)
            } else {
                variance = sumSquaredDeviations / (m - 1.0)
            }
            return variance
        }
        """
        #expect(divisionLines(code) == [9])
    }

    // MARK: - Invalidation

    @Test("A var reassigned after the guard still fires")
    func flagsVarReassignedAfterGuard() {
        let code = """
        func variance(m2: Double, values: [Double]) -> Double {
            var n = values.count
            guard n > 1 else { return 0 }
            n -= 1
            return m2 / Double(n - 1)
        }
        """
        #expect(divisionLines(code) == [5])
    }

    @Test("A collection mutated after the guard still fires")
    func flagsCollectionMutatedAfterGuard() {
        let code = """
        func variance(m2: Double, values: [Double]) -> Double {
            var kept = values
            guard kept.count >= 2 else { return 0 }
            kept.removeLast()
            return m2 / Double(kept.count - 1)
        }
        """
        #expect(divisionLines(code) == [5])
    }

    @Test("A method called on an element does not change the collection's count")
    func clearsCountAfterElementMethodCall() {
        let code = """
        struct Metric { let value: Double; func improvementFrom(_ other: Metric) -> Double { value - other.value } }
        final class Progress {
            private var recentMetrics: [Metric] = []
            private func calculateAverageImprovement() -> Double {
                guard recentMetrics.count >= 2 else { return 0 }
                var totalImprovement = 0.0
                for i in 1..<recentMetrics.count {
                    totalImprovement += recentMetrics[i].improvementFrom(recentMetrics[i - 1])
                }
                return totalImprovement / Double(recentMetrics.count - 1)
            }
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("An unknown method called on a stored collection ends a claim about its count")
    func flagsCountAfterUnknownMethodCall() {
        let code = """
        final class Progress {
            private var recentMetrics: [Double] = []
            private func average(total: Double) -> Double {
                guard recentMetrics.count >= 2 else { return 0 }
                recentMetrics.trim(to: 1)
                return 100.0 * total / Double(recentMetrics.count - 1)
            }
        }
        """
        #expect(divisionLines(code) == [6])
    }

    @Test("A name a closure assigns is never known: the closure may run after the guard")
    func flagsNameAssignedInClosure() {
        let code = """
        func variance(m2: Double, values: [Double]) -> Double {
            var n = values.count
            let reset = { n = 1 }
            guard n > 1 else { return 0 }
            reset()
            return 100.0 * m2 / Double(n - 1)
        }
        """
        #expect(divisionLines(code) == [6])
    }

    @Test("A name a local function assigns is never known")
    func flagsNameAssignedInLocalFunction() {
        let code = """
        func variance(m2: Double, values: [Double]) -> Double {
            var kept = values
            func drain() { kept.removeAll() }
            guard kept.count >= 2 else { return 0 }
            drain()
            return 100.0 * m2 / Double(kept.count - 1)
        }
        """
        #expect(divisionLines(code) == [6])
    }

    @Test("A strict bound does not survive a narrowing conversion")
    func flagsStrictBoundThroughFloat() {
        let code = """
        func inverse(x: Double) -> Float {
            guard x > 1 else { return 0 }
            return 1.0 / (Float(x) - 1.0)
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A closure that assigns one member does not end a claim about another")
    func clearsMemberWhenClosureAssignsSibling() {
        let code = """
        final class TimeState { var totalSteps = 0; var currentTimeIndex = 0 }
        struct Controls {
            let state: TimeState
            var scrub: (Int) -> Void { { index in state.currentTimeIndex = index } }
            var progressFraction: CGFloat {
                guard state.totalSteps > 1 else { return 0 }
                return CGFloat(state.currentTimeIndex) / max(CGFloat(state.totalSteps - 1), .leastNonzeroMagnitude)
            }
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A closure in the same body that assigns the member ends every claim about it there")
    func flagsMemberWhenLocalClosureAssignsIt() {
        let code = """
        final class TimeState { var totalSteps = 0; var currentTimeIndex = 0 }
        struct Controls {
            let state: TimeState
            var progressFraction: CGFloat {
                let reset = { state.totalSteps = 1 }
                guard state.totalSteps > 1 else { return 0 }
                reset()
                return CGFloat(state.currentTimeIndex) / max(CGFloat(state.totalSteps - 1), .leastNonzeroMagnitude)
            }
        }
        """
        #expect(divisionLines(code) == [8])
    }

    @Test("A closure elsewhere in the type is other code, as a method is: it does not end a claim")
    func clearsMemberWhenAnotherMembersClosureCallsAMethod() {
        let code = """
        final class TimeState { var totalSteps = 0; var currentTimeIndex = 0; func reset() { totalSteps = 0 } }
        struct Controls {
            var state: TimeState
            var onReset: () -> Void { { state.reset() } }
            var progressFraction: CGFloat {
                guard state.totalSteps > 1 else { return 0 }
                return CGFloat(state.currentTimeIndex) / max(CGFloat(state.totalSteps - 1), .leastNonzeroMagnitude)
            }
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("At file scope a closure that assigns a name ends every claim about it")
    func flagsTopLevelNameAssignedInClosure() {
        let code = """
        var n = CommandLine.arguments.count
        let reset = { n = 1 }
        guard n > 1 else { exit(0) }
        reset()
        print(100.0 / Double(n - 1))
        """
        #expect(divisionLines(code) == [5])
    }

    @Test("A closure parameter shadowing the guarded name still fires")
    func flagsShadowedGuardedName() {
        let code = """
        func spread(m2: Double, n: Int, sizes: [Int]) -> [Double] {
            guard n > 1 else { return [] }
            return sizes.map { n in m2 / Double(n - 1) }
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A mutation later in a loop that the guard sits outside still fires")
    func flagsMutationLaterInLoop() {
        let code = """
        func drain(m2: Double, start: Int) -> Double {
            var n = start
            var total = 0.0
            guard n > 1 else { return 0 }
            for _ in 0..<3 {
                total += m2 / Double(n - 1)
                n -= 1
            }
            return total
        }
        """
        #expect(divisionLines(code) == [6])
    }

    // MARK: - n + k

    @Test("A bound of at least one covers n + 1")
    func clearsPlusOneUnderGuard() {
        let code = """
        func weights(lags: Int) -> [Double] {
            var out: [Double] = []
            if lags >= 1 {
                for l in 1...lags {
                    out.append(1.0 - Double(l) / Double(lags + 1))
                }
            }
            return out
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("n + 1 with nothing known about n still fires")
    func flagsPlusOneUnguarded() {
        let code = """
        func weight(l: Int, lags: Int) -> Double {
            return 1.0 - Double(l) / Double(lags + 1)
        }
        """
        #expect(divisionLines(code) == [2])
    }

    // MARK: - Products

    @Test("A product of a guarded count and a guarded rate is a nonzero divisor")
    func clearsProductOfCountAndRate() {
        let code = """
        func density(_ signal: [Double], sampleRate: Double) -> Double {
            guard signal.isEmpty == false, sampleRate > 0 else { return 0 }
            let unpaddedLength = signal.count
            let typicalFactor = 2.0 / (Double(unpaddedLength) * sampleRate)
            return typicalFactor
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A product with a factor at least eight and a guarded variance is a nonzero divisor")
    func clearsProductWithLargeFactors() {
        let code = """
        func statistic(partials: [Double], n: Int, raw: Double) -> Double {
            var sumSquaredPartials = 0.0
            for partial in partials { sumSquaredPartials += partial * partial }
            guard n >= 8 else { return .nan }
            let nDouble = Double(n)
            var variance = raw
            variance += 1.0
            guard variance > 0 else { return .nan }
            let stat = sumSquaredPartials / (nDouble * nDouble * variance)
            return stat
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A literal of magnitude at least one times a guarded value is a nonzero divisor")
    func clearsLiteralTimesGuardedValue() {
        let code = """
        func centroid(sum: Double, rawArea: Double) -> Double {
            var area = rawArea
            var cx = 0.0
            cx += sum
            area *= 0.5
            guard abs(area) > 1e-10 else { return 0 }
            cx /= (6 * area)
            return cx
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A product with an unguarded factor still fires")
    func flagsProductWithUnguardedFactor() {
        let code = """
        func density(_ signal: [Double], sampleRate: Double) -> Double {
            guard signal.isEmpty == false else { return 0 }
            let unpaddedLength = signal.count
            return 2.0 / (Double(unpaddedLength) * sampleRate)
        }
        """
        #expect(divisionLines(code) == [4])
    }

    @Test("A product of two guarded values of unknown magnitude still fires: it can underflow to zero")
    func flagsProductOfTwoSmallFactors() {
        let code = """
        func inverse(a: Double, b: Double) -> Double {
            guard a > 0, b > 0 else { return 0 }
            return 1.0 / (a * b)
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A literal below one times a guarded value still fires: it can underflow to zero")
    func flagsFractionTimesGuardedValue() {
        let code = """
        func centroid(sum: Double, area: Double) -> Double {
            guard abs(area) > 0 else { return 0 }
            return 1.0 / (0.5 * area)
        }
        """
        #expect(divisionLines(code) == [3])
    }
}
