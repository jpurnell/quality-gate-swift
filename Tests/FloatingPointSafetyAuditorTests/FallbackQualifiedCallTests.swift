import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

private func audit(_ source: String) -> FallbackAuditResult {
    FallbackRules.audit(source: source, fileName: "Sources/Widgets/ProgressBarLayout.swift")
}

private func unguardedLines(_ source: String) -> [Int] {
    audit(source).diagnostics
        .filter { $0.ruleId == FallbackRuleID.intConversionUnguarded }
        .compactMap(\.lineNumber)
}

// A false negative, found by the 2026-10-09 portfolio survey. Only a bare `min` or
// `max` was read as carrying its arguments' value; the same call written
// `Swift.min(…)` evaluated to nothing known, the local it was bound to took no type,
// and every conversion downstream of it was never examined.

@Suite("fallback: a module-qualified call carries a NaN exactly as the bare call does")
struct FallbackQualifiedCallTests {

    @Test("SwiftCLIKit ProgressBarLayout: Int(ratio * 100) after Swift.min(Swift.max(…))")
    func flagsConversionAfterQualifiedClamp() {
        let code = """
        public struct ProgressBarLayout {
            public let label: String?

            public init(current: Double, total: Double, showPercentage: Bool) {
                guard total > 0 else {
                    label = nil
                    return
                }
                let ratio = Swift.min(Swift.max(current / total, 0.0), 1.0)
                label = showPercentage ? "\\(Int(ratio * 100))%" : nil
            }
        }
        """
        // `current` is never tested. A NaN is first at both levels of the clamp, so it
        // comes out the other side and `Int(.nan * 100)` stops the process.
        #expect(unguardedLines(code) == [10])
        #expect(audit(code).conversionsExamined == 1)
    }

    @Test("The bare spelling of the same clamp is reported on the same line")
    func bareSpellingAgrees() {
        let code = """
        public struct ProgressBarLayout {
            public let label: String?

            public init(current: Double, total: Double, showPercentage: Bool) {
                guard total > 0 else {
                    label = nil
                    return
                }
                let ratio = min(max(current / total, 0.0), 1.0)
                label = showPercentage ? "\\(Int(ratio * 100))%" : nil
            }
        }
        """
        #expect(unguardedLines(code) == [10])
    }

    @Test("Guarding the value that enters the qualified clamp clears the conversion")
    func acceptsGuardedQualifiedClamp() {
        let code = """
        public struct ProgressBarLayout {
            public let label: String?

            public init(current: Double, total: Double, showPercentage: Bool) {
                guard total > 0, current.isFinite, total.isFinite else {
                    label = nil
                    return
                }
                let fraction = current / total
                guard fraction.isFinite else {
                    label = nil
                    return
                }
                let ratio = Swift.min(Swift.max(fraction, 0.0), 1.0)
                label = showPercentage ? "\\(Int(ratio * 100))%" : nil
            }
        }
        """
        #expect(unguardedLines(code) == [])
        #expect(audit(code).conversionsExamined == 1)
    }

    @Test("SwiftExcelFunctions: Int of a Foundation.floor result")
    func flagsConversionAfterQualifiedRounding() {
        let code = """
        func wholePart(_ value: Double) -> Int {
            let floored = Foundation.floor(value)
            return Int(floored)
        }
        """
        #expect(unguardedLines(code) == [3])
    }

    @Test("Converted in place, with no local between the qualified call and Int")
    func flagsDirectConversionOfQualifiedCall() {
        let code = """
        func wholePart(_ value: Double) -> Int {
            return Int(Swift.abs(value))
        }
        """
        #expect(unguardedLines(code) == [2])
    }

    @Test("A qualified min of integers is still not a floating-point value")
    func ignoresQualifiedMinOfIntegers() {
        let code = """
        func slot(index: Int, count: Int) -> Int {
            let bounded = Swift.min(Swift.max(index, 0), count - 1)
            return Int(bounded)
        }
        """
        #expect(unguardedLines(code) == [])
        #expect(audit(code).conversionsExamined == 0)
    }

    @Test("A member call on an arbitrary base is not a module-qualified function")
    func ignoresMethodNamedLikeAFunction() {
        let code = """
        func slot(layout: Layout, value: Int) -> Int {
            let bounded = layout.max(value)
            return Int(bounded)
        }
        """
        #expect(unguardedLines(code) == [])
        #expect(audit(code).conversionsExamined == 0)
    }

    @Test("A qualified clamp with the value second is seen by clamp-absorbs-nan too")
    func qualifiedClampAbsorbingStillReported() {
        let code = """
        func unit(_ value: Double) -> Double {
            return Swift.max(0.0, Swift.min(1.0, value))
        }
        """
        let clamps = audit(code).diagnostics.filter { $0.ruleId == FallbackRuleID.clampAbsorbsNaN }
        #expect(clamps.compactMap(\.lineNumber) == [2])
    }
}
