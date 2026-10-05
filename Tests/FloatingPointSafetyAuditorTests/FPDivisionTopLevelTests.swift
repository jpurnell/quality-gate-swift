import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// Top-level code is a body too. A script, a `main.swift` or a playground page asks whether a
// divisor is zero in the same spellings a function does, and the file scope used to hold no
// record of it — so a guarded division at file scope was reported, and the only repairs were
// to move the code into a function or to put the bound inline.

private let divisionRule = "fp-division-unguarded"

private func divisionLines(_ source: String, fileName: String = "Sources/Example/main.swift") -> [Int] {
    FloatingPointRules.audit(
        source: source,
        fileName: fileName,
        options: .sources(checkDivisionGuards: true)
    ).diagnostics.filter { $0.ruleId == divisionRule }.compactMap(\.lineNumber)
}

@Suite("fp-division-unguarded: top-level code")
struct FPDivisionTopLevelTests {

    @Test("A ternary at file scope guards the division in its own branch")
    func topLevelTernaryGuards() {
        let code = """
        let values = [1.0, 2.0]
        let count = Double(values.count)
        let mean = count > 0 ? values.reduce(0, +) / count : 0
        print(mean)
        """
        #expect(divisionLines(code) == [])
    }

    @Test("An if at file scope guards the division inside it")
    func topLevelIfGuards() {
        let code = """
        let n = 4
        let d = Double(n)
        if d > 0 {
            print(10.0 / d)
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A guard at file scope guards what follows it")
    func topLevelGuardGuards() {
        let code = """
        import Foundation
        let n = CommandLine.arguments.count
        let d = Double(n)
        guard d > 0 else { exit(1) }
        print(10.0 / d)
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A check inside a file-scope do block guards the division beside it")
    func topLevelDoBlockGuards() {
        let code = """
        do {
            let n = 3
            let d = Double(n)
            let r = d > 0 ? 1.0 / d : 0
            print(r)
        }
        """
        #expect(divisionLines(code) == [])
    }

    @Test("A file-scope check on what the divisor was converted from covers the conversion")
    func topLevelCheckThroughAnAlias() {
        let code = """
        import Foundation
        let values = [1.0, 2.0]
        guard values.count > 0 else { exit(1) }
        let count = Double(values.count)
        print(values.reduce(0, +) / count)
        """
        #expect(divisionLines(code) == [])
    }

    @Test("An unchecked division at file scope is still reported")
    func topLevelUncheckedIsReported() {
        let code = """
        let n = 3
        let d = Double(n)
        print(1.0 / d)
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A check written after the division at file scope did not protect it")
    func topLevelCheckAfterIsReported() {
        let code = """
        let n = 3
        let d = Double(n)
        print(1.0 / d)
        if d > 0 { print("positive") }
        """
        #expect(divisionLines(code) == [3])
    }

    @Test("A guard inside a type's member does not answer for file-scope code")
    func memberGuardDoesNotReachFileScope() {
        let code = """
        let n = 3
        let d = Double(n)
        struct Rate {
            let value: Double
            init?(d: Double) {
                guard d > 0 else { return nil }
                value = 1.0 / d
            }
            var doubled: Double {
                guard d > 0 else { return 0 }
                return 2.0 / d
            }
        }
        print(1.0 / d)
        """
        #expect(divisionLines(code) == [14])
    }

    @Test("A guard inside a function does not answer for file-scope code")
    func functionGuardDoesNotReachFileScope() {
        let code = """
        let n = 3
        let d = Double(n)
        func half(_ d: Double) -> Double {
            guard d > 0 else { return 0 }
            return 0.5 / d
        }
        print(1.0 / d)
        """
        #expect(divisionLines(code) == [7])
    }
}
