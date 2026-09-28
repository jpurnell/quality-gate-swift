import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

private func clampFindings(
    _ source: String,
    filePath: String = "Sources/Statistics/kendallW.swift"
) -> [Diagnostic] {
    FallbackRules.audit(source: source, fileName: filePath)
        .diagnostics
        .filter { $0.ruleId == FallbackRuleID.clampAbsorbsNaN }
}

// MARK: - The sites that answered
//
// From BusinessMath at `464cf939`. Kendall's W reported 1.0 — perfect
// concordance — for a sample that supported none.

@Suite("fallback.clamp-absorbs-nan: the sites that answered")
struct FallbackClampSiteTests {

    @Test("Kendall's W: max(T(0), min(T(1), w)) returns 1 for a NaN")
    func flagsKendallW() {
        let code = """
        func kendallW<T: Real>(ranks: [[T]]) -> T {
            let w: T = concordance(ranks)
            return max(T(0), min(T(1), w))
        }
        """
        let findings = clampFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 3)
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.message.contains("'w'") == true)
        #expect(findings.first?.message.contains("'T(1)'") == true)
    }

    @Test("Kendall's W: a quotient inside the clamp can be NaN from finite operands")
    func flagsQuotientInsideClamp() {
        let code = """
        func kendallW<T: Real>(s: T, denom: T) -> T {
            guard s.isFinite, denom.isFinite else { return T.nan }
            return max(T(0), min(T(1), (T(12) * s) / denom))
        }
        """
        let findings = clampFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 3)
    }

    @Test("Trend confidence: Swift.max(0, Swift.min(1, rSquared))")
    func flagsQualifiedSwiftMinMax() {
        let code = """
        func confidence(ssResidual: Double, ssTotal: Double) -> Double {
            let rSquared = 1.0 - (ssResidual / ssTotal)
            return Swift.max(0, Swift.min(1, rSquared))
        }
        """
        let findings = clampFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 3)
        #expect(findings.first?.message.contains("'rSquared'") == true)
    }
}

// MARK: - Argument order

@Suite("fallback.clamp-absorbs-nan: argument order decides")
struct FallbackClampOrderTests {

    // Measured: max(0, min(nan, 1)) == 0.
    @Test("Value first in the inner call, inner call second in the outer: returns the outer bound")
    func flagsValueFirstInnerSecond() {
        let code = """
        func clampMomentum(momentum: Double) -> Double {
            return max(0.0, min(momentum, 0.99))
        }
        """
        let findings = clampFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.message.contains("'0.0'") == true)
    }

    // Measured: min(1, max(0, nan)) == 0.
    @Test("min outside, max inside: the same absorption")
    func flagsMinOfMax() {
        let code = """
        func clampRatio(ratio: Double) -> Double {
            return min(1.0, max(0.0, ratio))
        }
        """
        #expect(clampFindings(code).count == 1)
    }

    // Measured: max(min(nan, 1), 0) is nan.
    @Test("Value first at both levels propagates a NaN: no finding")
    func acceptsPropagatingOrder() {
        let code = """
        func clampRatio(ratio: Double) -> Double {
            return max(min(ratio, 1.0), 0.0)
        }
        """
        #expect(clampFindings(code).isEmpty)
    }

    // Measured: min(max(nan, 0), 1) is nan.
    @Test("Value first at both levels, min outside: no finding")
    func acceptsPropagatingOrderMinOutside() {
        let code = """
        func clampRatio(ratio: Double) -> Double {
            return min(max(ratio, 0.0), 1.0)
        }
        """
        #expect(clampFindings(code).isEmpty)
    }
}

// MARK: - What answers the question

@Suite("fallback.clamp-absorbs-nan: what answers the question")
struct FallbackClampGuardTests {

    @Test("An isNaN test before the clamp: no finding")
    func acceptsIsNaNTest() {
        let code = """
        func clampRatio(ratio: Double) -> Double {
            if ratio.isNaN { return .nan }
            return max(0.0, min(1.0, ratio))
        }
        """
        #expect(clampFindings(code).isEmpty)
    }

    @Test("An isFinite guard before the clamp: no finding")
    func acceptsIsFiniteGuard() {
        let code = """
        func clampRatio(ratio: Double) -> Double {
            guard ratio.isFinite else { return .nan }
            return max(0.0, min(1.0, ratio))
        }
        """
        #expect(clampFindings(code).isEmpty)
    }

    @Test("A comparison asserted by a guard excludes a NaN: no finding")
    func acceptsAssertedComparison() {
        let code = """
        func clampRatio(ratio: Double) -> Double {
            guard ratio > -10 else { return .nan }
            return max(0.0, min(1.0, ratio))
        }
        """
        #expect(clampFindings(code).isEmpty)
    }

    @Test("A product of checked values cannot be NaN: no finding")
    func acceptsCheckedProduct() {
        let code = """
        func clampScaled(ratio: Double, weight: Double) -> Double {
            guard ratio.isFinite, weight.isFinite else { return .nan }
            return max(0.0, min(1.0, ratio * weight))
        }
        """
        #expect(clampFindings(code).isEmpty)
    }

    @Test("A test after the clamp answers nothing")
    func flagsTestAfterClamp() {
        let code = """
        func clampRatio(ratio: Double) -> Double {
            let clamped = max(0.0, min(1.0, ratio))
            if ratio.isNaN { return .nan }
            return clamped
        }
        """
        let findings = clampFindings(code)
        #expect(findings.count == 1)
        #expect(findings.first?.lineNumber == 2)
    }
}

// MARK: - What is not a finding

@Suite("fallback.clamp-absorbs-nan: what is not a finding")
struct FallbackClampExclusionTests {

    // BusinessMath `convergenceDiagnostics.swift:144`.
    @Test("An integer clamp has no NaN to absorb")
    func ignoresIntegerClamp() {
        let code = """
        func effectiveSize(essInt: Int, n: Int) -> Int {
            return max(1, min(essInt, n))
        }
        """
        #expect(clampFindings(code).isEmpty)
    }

    @Test("A clamp of literals")
    func ignoresLiteralClamp() {
        let code = """
        func f() -> Double {
            return max(0.0, min(1.0, 0.5))
        }
        """
        #expect(clampFindings(code).isEmpty)
    }

    @Test("A name whose type is not known is skipped")
    func ignoresUnknownValue() {
        let code = """
        func f() -> Double {
            return max(0.0, min(1.0, somethingFromAnotherFile))
        }
        """
        #expect(clampFindings(code).isEmpty)
    }

    @Test("A single min is not a clamp")
    func ignoresSingleMin() {
        let code = """
        func f(ratio: Double) -> Double {
            return min(1.0, ratio)
        }
        """
        #expect(clampFindings(code).isEmpty)
    }

    @Test("min inside min is not a clamp")
    func ignoresSameFunctionNesting() {
        let code = """
        func f(a: Double, b: Double, c: Double) -> Double {
            return min(a, min(b, c))
        }
        """
        #expect(clampFindings(code).isEmpty)
    }

    @Test("Test files are not production code")
    func skipsTestFiles() {
        let code = """
        func clampRatio(ratio: Double) -> Double {
            return max(0.0, min(1.0, ratio))
        }
        """
        #expect(clampFindings(code, filePath: "Tests/StatsTests/ClampTests.swift").isEmpty)
    }
}
