import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

private func lines(_ ruleId: String, in source: String) -> [Int] {
    FallbackRules.audit(source: source, fileName: "Sources/Charts/Scale.swift")
        .diagnostics
        .filter { $0.ruleId == ruleId }
        .compactMap(\.lineNumber)
}

private func clampLines(_ source: String) -> [Int] {
    lines(FallbackRuleID.clampAbsorbsNaN, in: source)
}

private func classificationLines(_ source: String) -> [Int] {
    lines(FallbackRuleID.classificationOmitsNaN, in: source)
}

private func unguardedLines(_ source: String) -> [Int] {
    lines(FallbackRuleID.intConversionUnguarded, in: source)
}

// Near misses of the shapes the 2026-10-09 precision work accepts. Each is a place
// where a fact about one value could be mistaken for a fact about another.

@Suite("fallback: a fact about one value is not a fact about its namesake")
struct FallbackSoundnessTests {

    @Test("A second loop reusing the element name over an untested collection is still reported")
    func flagsSecondLoopOverUntestedCollection() {
        let code = """
        func signs(values: [Double], others: [Double]) -> Int {
            guard values.allSatisfy({ $0.isFinite }) else { return 0 }
            var total = 0
            for value in values {
                if value < 0 {
                    total -= 1
                } else if value > 0 {
                    total += 1
                }
            }
            for value in others {
                if value < 0 {
                    total -= 1
                } else if value > 0 {
                    total += 1
                }
            }
            return total
        }
        """
        #expect(classificationLines(code) == [12])
    }

    @Test("A clamp in a second loop over an untested collection is still reported")
    func flagsClampInSecondLoop() {
        let code = """
        func unit(values: [Double], others: [Double]) -> Double {
            guard values.allSatisfy({ !$0.isNaN }) else { return 0 }
            var total = 0.0
            for value in values {
                total += max(0.0, min(1.0, value))
            }
            for value in others {
                total += max(0.0, min(1.0, value))
            }
            return total
        }
        """
        #expect(clampLines(code) == [8])
    }

    @Test("The loop's element name used after the loop for another value is not the element")
    func flagsNameReusedAfterLoop() {
        let code = """
        func unit(values: [Double], raw: Double) -> Double {
            guard values.allSatisfy({ !$0.isNaN }) else { return 0 }
            var total = 0.0
            for value in values {
                total += value
            }
            let value = raw
            return total + max(0.0, min(1.0, value))
        }
        """
        #expect(clampLines(code) == [8])
    }

    @Test("A collection that is reassigned after it was tested is not the collection that was tested")
    func flagsCollectionReassignedAfterTest() {
        let code = """
        func signs(input: [Double], extra: [Double]) -> Int {
            var values = input
            guard values.allSatisfy({ $0.isFinite }) else { return 0 }
            values = extra
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
        #expect(classificationLines(code) == [7])
    }

    @Test("A collection appended to after it was tested may hold a NaN again")
    func flagsCollectionAppendedAfterTest() {
        let code = """
        func signs(input: [Double], extra: Double) -> Int {
            var values = input
            guard values.allSatisfy({ $0.isFinite }) else { return 0 }
            values.append(extra)
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
        #expect(classificationLines(code) == [7])
    }

    @Test("An else whose yielded value was reassigned from something else answers for the NaN")
    func flagsElseYieldingShadowedSubject() {
        let code = """
        func pick(_ p: Double, fallback: Double) -> Double {
            if p < 0 {
                return 0
            } else if p > 1 {
                return 1
            } else {
                let p = fallback
                return p
            }
        }
        """
        #expect(classificationLines(code) == [2])
    }

    @Test("A closure parameter named like the derived local's operand is not that operand")
    func flagsClosureParameterShadowingOperand() {
        let code = """
        func normalise(_ values: [Double], lower: Double, upper: Double) -> [Double] {
            let span = upper - lower
            guard span > 0 else { return values }
            return values.map { (upper: Double) -> Double in
                Swift.min(Swift.max(0.5, 0.0), upper)
            }
        }
        """
        #expect(clampLines(code) == [5])
    }

    @Test("In an arm that reassigns the value, the condition no longer describes it")
    func flagsValueReassignedInsideArm() {
        let code = """
        func slot(start: Double, raw: Double) -> Int {
            var position = start
            if position >= 0 && position < 4_096 {
                position = raw
                return Int(position)
            }
            return 0
        }
        """
        #expect(unguardedLines(code) == [5])
    }

    @Test("A local of that name bound twice in the body is not followed to either range")
    func flagsLocalRangeBoundTwice() {
        let code = """
        func step(angle: Double, wide: Bool, limits: Set<Double>) -> Int {
            if wide {
                let allowed = -90.0...90.0
                print(allowed)
            }
            let allowed = limits
            guard allowed.contains(angle) else { return 0 }
            return Int(angle)
        }
        """
        #expect(unguardedLines(code) == [8])
    }

    @Test("A local range declared in a later, separate block does not bound an earlier test")
    func flagsLocalRangeDeclaredAfterTheTest() {
        let code = """
        struct Dial {
            let allowed: Set<Double>

            func step(angle: Double) -> Int {
                guard allowed.contains(angle) else { return 0 }
                let whole = Int(angle)
                let allowed = -90.0...90.0
                print(allowed)
                return whole
            }
        }
        """
        #expect(unguardedLines(code) == [6])
    }

    @Test("A local range constant in one function does not vouch for a member of the same name in another")
    func flagsMemberNamedLikeALocalRange() {
        let code = """
        struct Dial {
            func step(angle: Double) -> Int {
                let allowed = -90.0...90.0
                guard allowed.contains(angle) else { return 0 }
                return Int(angle)
            }
        }

        extension Registry {
            func whole(df: Double) -> Int {
                guard allowed.contains(df) else { return 0 }
                return Int(df)
            }
        }
        """
        #expect(unguardedLines(code) == [12])
    }
}
