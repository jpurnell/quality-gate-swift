import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// A division is reported where its operator is. An expression spread over several lines used
// to report every division in it at the expression's first line, so one marker on that line
// silenced all of them — including the ones its reason did not describe.

private let divisionRule = "fp-division-unguarded"

private func audit(_ source: String) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
    let result = FloatingPointRules.audit(
        source: source,
        fileName: "Sources/Example/test.swift",
        options: .sources(checkDivisionGuards: true)
    )
    return (result.diagnostics.filter { $0.ruleId == divisionRule },
            result.overrides.filter { $0.ruleId == divisionRule })
}

@Suite("fp-division-unguarded: reported at the operator")
struct FPDivisionOperatorLineTests {

    @Test("Two divisions in one multi-line expression are reported on their own lines")
    func reportsEachDivisionOnItsOperatorLine() {
        let code = """
        func blend(a: Double, b: Double, c: Double) -> Double {
            let r = a
                / b
                + 1.0
                / c
            return r
        }
        """
        #expect(audit(code).diagnostics.compactMap(\.lineNumber) == [3, 5])
    }

    @Test("The column is the operator's")
    func reportsOperatorColumn() {
        let code = """
        func blend(a: Double, b: Double) -> Double {
            let r = a
                / b
            return r
        }
        """
        let found = audit(code).diagnostics
        #expect(found.compactMap(\.lineNumber) == [3])
        #expect(found.compactMap(\.columnNumber) == [9])
    }

    @Test("A marker on the expression's first line no longer silences a division below it")
    func firstLineMarkerDoesNotReachOperatorLine() {
        let code = """
        func blend(a: Double, b: Double, c: Double) -> Double {
            let r = a // fp-safety:disable — b is validated by the caller
                / b
                + 1.0
                / c
            return r
        }
        """
        let result = audit(code)
        #expect(result.diagnostics.compactMap(\.lineNumber) == [3, 5])
        #expect(result.overrides.count == 0)
    }

    @Test("A marker on the operator's line silences that division and no other")
    func operatorLineMarkerSilencesOnlyItsDivision() {
        let code = """
        func blend(a: Double, b: Double, c: Double) -> Double {
            let r = a
                / b // fp-safety:disable — b is validated by the caller
                + 1.0
                / c
            return r
        }
        """
        let result = audit(code)
        #expect(result.diagnostics.compactMap(\.lineNumber) == [5])
        #expect(result.overrides.map(\.lineNumber) == [3])
    }

    @Test("A single-line division keeps its line, and its marker keeps its effect")
    func singleLineMarkerUnchanged() {
        let code = """
        func blend(a: Double, b: Double, c: Double) -> Double {
            let first = a / b // fp-safety:disable — b is validated by the caller
            // fp-safety:disable — c is validated by the caller
            let second = a / c
            return first + second + a / b
        }
        """
        let result = audit(code)
        #expect(result.diagnostics.compactMap(\.lineNumber) == [5])
        #expect(result.overrides.map(\.lineNumber) == [2, 4])
    }

    @Test("A compound division is reported at its operator")
    func reportsCompoundDivisionAtOperator() {
        let code = """
        func scale(_ total: inout Double, by d: Double) {
            total
                /= d
        }
        """
        #expect(audit(code).diagnostics.compactMap(\.lineNumber) == [3])
    }
}
