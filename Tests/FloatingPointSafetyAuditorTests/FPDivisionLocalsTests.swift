import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// `ALocalIsNotAGuard`: a `let` carries the evidence its initializer carries, and a guard is
// read in the spellings people write for it — in order, through aliases.

private let divisionRule = "fp-division-unguarded"
private let equalityRule = "fp-equality"

/// Runs the floating-point rules over `source` through the entry point both checkers use, so
/// the file-local return types are collected as they are in a real run.
private func audit(_ source: String) -> [Diagnostic] {
    FloatingPointRules.audit(
        source: source,
        fileName: "Sources/Example/test.swift",
        options: .sources(checkDivisionGuards: true)
    ).diagnostics
}

/// The 1-based lines of every unguarded-division finding in `source`, in order.
private func divisionLines(_ source: String) -> [Int] {
    audit(source).filter { $0.ruleId == divisionRule }.compactMap(\.lineNumber)
}

extension FPDivisionTests {

    // MARK: - Evidence through `let` (§3.1)

    @Test("A local bound from a conversion is examined as a divisor")
    func flagsConversionBoundLocal() {
        let code = """
        func f(x: Double, n: Int) -> Double {
            let d = Double(n)
            return x / d
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A var bound from a conversion is examined under /=")
    func flagsConversionBoundVarCompound() {
        let code = """
        func f(_ y: inout Double, n: Int) {
            var d = Double(n)
            d += 0.5
            y /= d
        }
        """
        #expect(divisionLines(code) == [4])
    }

    @Test("A name bound from a directly evidenced name stays directly evidenced")
    func flagsLocalOfLocal() {
        let code = """
        func f(x: Double, n: Int) -> Double {
            let a = Double(n)
            let b = a
            return x / b
        }
        """
        #expect(divisionLines(code) == [4])
    }

    @Test("A local bound from a file-local function's return type is still not examined")
    func exemptReturnTypeChain() {
        let code = """
        func mean(_ v: [Double]) -> Double {
            v.reduce(0.0, +)
        }
        func f(x: Double, v: [Double]) -> Double {
            let m = mean(v)
            return x / m
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("Arithmetic is not evidence on either side of the =")
    func exemptArithmeticBoundLocal() {
        let code = """
        func f(x: Double, a: Double, b: Double) -> Double {
            let d = a - b
            return x / d
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("The evidence change does not leak into fp-equality")
    func equalityUnmovedByEvidence() {
        let code = """
        func f(n: Int) {
            let d = Double(n)
            if d == 1.5 {}
        }
        """
        let found = audit(code)
        #expect(found.filter { $0.ruleId == equalityRule }.count == 1)
        #expect(found.count == 1)
    }

    // MARK: - Guard spellings (§3.3)

    @Test("isEmpty == false is a guard on count")
    func exemptIsEmptyEqualsFalse() {
        let code = """
        func f(xs: [Double], s: Double) -> Double {
            guard xs.isEmpty == false else { return 0 }
            return s / Double(xs.count)
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("false == isEmpty is a guard on count")
    func exemptFalseEqualsIsEmpty() {
        let code = """
        func f(xs: [Double], s: Double) -> Double {
            guard false == xs.isEmpty else { return 0 }
            return s / Double(xs.count)
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("isEmpty as a ternary condition is a guard on count")
    func exemptIsEmptyTernary() {
        let code = """
        func f(xs: [Double], s: Double) -> Double {
            return xs.isEmpty ? 0 : s / Double(xs.count)
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("An early return on isEmpty is a guard on count")
    func exemptIsEmptyEarlyReturn() {
        let code = """
        func f(xs: [Double], s: Double) -> Double {
            if xs.isEmpty { return 0 }
            return s / Double(xs.count)
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test(">= a positive literal is a guard", arguments: ["1", "4"])
    func exemptGreaterOrEqualPositive(threshold: String) {
        let code = """
        func f(x: Double, n: Int) -> Double {
            guard n >= \(threshold) else { return 0 }
            return x / Double(n)
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test(">= 0 admits zero and is not a guard")
    func flagsGreaterOrEqualZero() {
        let code = """
        func f(x: Double, n: Int) -> Double {
            guard n >= 0 else { return 0 }
            return x / Double(n)
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A positive literal <= n is a guard")
    func exemptMirroredGreaterOrEqual() {
        let code = """
        func f(x: Double, n: Int) -> Double {
            guard 4 <= n else { return 0 }
            return x / Double(n)
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("0 < n is a guard")
    func exemptMirroredGreaterThanZero() {
        let code = """
        func f(x: Double, n: Int) -> Double {
            guard 0 < n else { return 0 }
            return x / Double(n)
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("d == 0 as a ternary condition is a guard")
    func exemptEqualsZeroTernary() {
        let code = """
        func f(x: Double, n: Int) -> Double {
            let d: Double = Double(n)
            return d == 0 ? 0 : x / d
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("span <= 0 with the division in the else arm is a guard")
    func exemptLessOrEqualZeroElse() {
        let code = """
        func f(x: Double, lo: Double, hi: Double) -> Double {
            let span: Double = hi - lo
            var r: Double
            if span <= 0 { r = 0 } else { r = x / span }
            return r
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("A ternary condition on the right of an assignment is a guard")
    func exemptAssignedTernary() {
        let code = """
        func f(meanRR: Double) -> Double {
            var restingHR: Double = 0
            restingHR = meanRR > 0 ? 60000.0 / meanRR : 0
            return restingHR
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("max(n, 1) cannot be zero")
    func exemptMaxWithNonZeroLiteral() {
        let code = """
        func f(x: Double, n: Int) -> Double {
            return x / Double(max(n, 1))
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("max(n, -1) can be zero")
    func flagsMaxWithNegativeBound() {
        let code = """
        func f(x: Double, n: Int) -> Double {
            return x / Double(max(n, -1))
        }
        """
        #expect(divisionLines(code) == [2])
    }

    // MARK: - Aliases and order (§3.2)

    @Test("LensPhaseAnalyzer.normalized: a guard on values.count clears a division by count")
    func exemptAliasedCountGuard() {
        let code = """
        private static func normalized(_ values: [Double]) -> [Double]? {
            guard values.isEmpty == false else { return nil }
            let count = Double(values.count)
            let mean = values.reduce(0.0, +) / count
            let centered = values.map { $0 - mean }
            let variance = centered.reduce(0.0) { $0 + $1 * $1 } / count
            let standardDeviation = variance.squareRoot()
            guard standardDeviation > flatnessEpsilon else { return nil }
            return centered.map { $0 / standardDeviation }
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("LensPhaseAnalyzer.normalized without its guard: both divisions by count are reported")
    func flagsAliasedCountWithoutGuard() {
        let code = """
        private static func normalized(_ values: [Double]) -> [Double]? {
            let count = Double(values.count)
            let mean = values.reduce(0.0, +) / count
            let centered = values.map { $0 - mean }
            let variance = centered.reduce(0.0) { $0 + $1 * $1 } / count
            let standardDeviation = variance.squareRoot()
            guard standardDeviation > flatnessEpsilon else { return nil }
            return centered.map { $0 / standardDeviation }
        }
        """
        #expect(divisionLines(code) == [3, 5])
    }

    @Test("A guard on xs.isEmpty clears a division by a local named for xs.count")
    func exemptGuardThroughAlias() {
        let code = """
        func f(xs: [Double]) -> Double {
            guard !xs.isEmpty else { return 0 }
            let count = Double(xs.count)
            let s: Double = xs.reduce(0.0, +)
            return s / count
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    @Test("A check written for a later division does not clear an earlier one")
    func flagsDivisionBeforeItsCheck() {
        let code = """
        func f(x: Sample) -> Double {
            let r = 60000.0 / x.rr
            record(r)
            let s = x.rr > 0 ? 60000.0 / x.rr : 0
            return s
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("A check after the division does not guard it")
    func flagsCheckAfterDivision() {
        let code = """
        func f(x: Double, n: Int) -> Double {
            let r = x / Double(n)
            if n > 0 { return r }
            return 0
        }
        """
        #expect(divisionLines(code) == [2])
    }

    @Test("A guard in the enclosing function clears a division inside a closure")
    func exemptGuardOutsideClosure() {
        let code = """
        func f(xs: [Double]) -> [Double] {
            guard !xs.isEmpty else { return [] }
            return xs.map { $0 / Double(xs.count) }
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    // MARK: - Tightening (§3.3 item 5)

    @Test("A comparison against another name is not a threshold")
    func flagsComparisonAgainstName() {
        let code = """
        func f(x: Double, segLen: Int, n: Int) -> Double {
            if segLen > n { record(segLen) }
            return x / Double(segLen)
        }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("!= 1 says nothing about zero")
    func flagsNotEqualToNonZero() {
        let code = """
        func f(x: Double, n: Int) -> Double {
            let d: Double = Double(n)
            guard d != 1 else { return x }
            return x / d
        }
        """
        #expect(divisionLines(code) == [4])
    }

    @Test("A generic threshold T(0) is still a threshold")
    func exemptGenericZeroThreshold() {
        let code = """
        func c<T: Real>(x: T) -> T {
            guard x > T(0) else { return T.nan }
            return T(1) / x
        }
        """
        #expect(divisionLines(code).isEmpty)
    }

    // MARK: - Negative control

    @Test("An examined local and a guarded count in one file: exactly the local is reported")
    func negativeControlLocalAndTernary() {
        let code = """
        func unguarded(x: Double, n: Int) -> Double {
            let d = Double(n)
            return x / d
        }
        func guarded(xs: [Double], s: Double) -> Double {
            return xs.isEmpty ? 0 : s / Double(xs.count)
        }
        """
        #expect(divisionLines(code) == [3])
    }
}

// MARK: - The shared collector

/// The facts both rules read. `fp-division-unguarded` and `fallback.*` ask one question —
/// is this safe to divide by? — so they are pinned on one collector, at the collector.
@Suite("FallbackGuardFactCollector: what counts as asking about zero")
struct GuardFactNonZeroTests {

    /// The keys a function body records a `.nonZero` fact for.
    private func nonZeroKeys(_ body: String, genericNames: Set<String> = []) -> Set<String> {
        let tree = Parser.parse(source: "func subject() {\n\(body)\n}")
        guard let function = tree.statements.first?.item.as(FunctionDeclSyntax.self),
              let block = function.body else {
            return []
        }
        let facts = FallbackGuardFactCollector.collect(from: Syntax(block), genericNames: genericNames)
        return Set(facts.facts.filter { $0.kind == .nonZero }.map(\.key))
    }

    @Test("isEmpty, in either sense, is a question about count")
    func emptinessEitherSense() {
        #expect(nonZeroKeys("if xs.isEmpty { return }") == ["xs.count"])
        #expect(nonZeroKeys("guard !self.values.isEmpty else { return }") == ["values.count"])
        #expect(nonZeroKeys("let ok = xs.isEmpty == false") == ["xs.count"])
    }

    @Test(">= needs a positive literal; its mirror too")
    func greaterOrEqual() {
        #expect(nonZeroKeys("guard n >= 2 else { return }") == ["n"])
        #expect(nonZeroKeys("guard 2 <= n else { return }") == ["n"])
        #expect(nonZeroKeys("guard n >= 0 else { return }").isEmpty)
        #expect(nonZeroKeys("guard n >= m else { return }").isEmpty)
    }

    @Test("== 0 and <= 0 ask the question in the negative sense")
    func negativeSense() {
        #expect(nonZeroKeys("if d == 0 { return }") == ["d"])
        #expect(nonZeroKeys("if 0.0 == d { return }") == ["d"])
        #expect(nonZeroKeys("if span <= 0 { return }") == ["span"])
        #expect(nonZeroKeys("if 0 >= span { return }") == ["span"])
        #expect(nonZeroKeys("if d == 1 { return }").isEmpty)
    }

    @Test("An assignment is an edge of a condition")
    func assignmentEdge() {
        #expect(nonZeroKeys("restingHR = meanRR > 0 ? 60000.0 / meanRR : 0") == ["meanRR"])
    }

    @Test("!= needs a zero; > and < need a literal or a smallest-magnitude constant")
    func tightened() {
        #expect(nonZeroKeys("if segLen > n { return }").isEmpty)
        #expect(nonZeroKeys("if n < segLen { return }").isEmpty)
        #expect(nonZeroKeys("guard d != 1 else { return }").isEmpty)
        #expect(nonZeroKeys("guard d != other else { return }").isEmpty)
        #expect(nonZeroKeys("guard d != 0 else { return }") == ["d"])
        #expect(nonZeroKeys("guard d != .zero else { return }") == ["d"])
        #expect(nonZeroKeys("guard d > 3 else { return }") == ["d"])
        #expect(nonZeroKeys("guard abs(d) > .ulpOfOne else { return }") == ["d"])
        #expect(nonZeroKeys("guard abs(d) > 1e-15 else { return }") == ["d"])
        #expect(nonZeroKeys("guard d > -1 else { return }").isEmpty)
    }

    @Test("A generic or numeric conversion of a literal is a literal")
    func convertedThresholds() {
        #expect(nonZeroKeys("guard x > T(0) else { return }", genericNames: ["T"]) == ["x"])
        #expect(nonZeroKeys("guard x > Double(0) else { return }") == ["x"])
        #expect(nonZeroKeys("guard x != T(0) else { return }", genericNames: ["T"]) == ["x"])
        #expect(nonZeroKeys("guard x > limit(0) else { return }").isEmpty)
    }
}
