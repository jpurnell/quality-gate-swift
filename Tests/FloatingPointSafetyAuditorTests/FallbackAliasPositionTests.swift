import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// `FallbackGuardFacts.aliases` was one dictionary per body, last write wins. A body that
// declares the same name twice — once in a closure, once outside it — had the later
// declaration stand for both, so checks made on the later one's value answered for a
// conversion of the earlier one's.

private func intConversionLines(_ source: String) -> [Int] {
    FallbackRules.audit(source: source, fileName: "Sources/Curves/DiscountCurve.swift")
        .diagnostics
        .filter { $0.ruleId == FallbackRuleID.intConversionUnguarded }
        .compactMap(\.lineNumber)
}

@Suite("fallback.int-conversion-unguarded: an alias is the declaration before the use")
struct FallbackAliasPositionTests {

    @Test("Checks on a later alias's value do not answer for an earlier alias of another value")
    func flagsEarlierAliasOfUncheckedValue() {
        let code = """
        func years(checked: Double, unchecked: Double) -> Int {
            guard checked.isFinite, checked >= 0, checked < 1_000 else { return 0 }
            let first: Int = {
                let tenor = unchecked
                return Int(tenor)
            }()
            let tenor = checked
            return first + Int(tenor)
        }
        """
        #expect(intConversionLines(code) == [5])
    }

    @Test("Checks on an earlier alias's value still answer for it after a later redeclaration")
    func clearsEarlierAliasOfCheckedValue() {
        let code = """
        func years(checked: Double, unchecked: Double) -> Int {
            guard checked.isFinite, checked >= 0, checked < 1_000 else { return 0 }
            let tenor = checked
            let first = Int(tenor)
            let second: Int = {
                let tenor = unchecked
                return Int(tenor)
            }()
            return first + second
        }
        """
        #expect(intConversionLines(code) == [7])
    }
}
