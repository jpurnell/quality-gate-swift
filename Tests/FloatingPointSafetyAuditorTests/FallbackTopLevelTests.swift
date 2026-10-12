import Foundation
import Testing
@testable import FloatingPointSafetyAuditor
@testable import QualityGateCore

// `fp-division-unguarded` learned to read the checks top-level code makes; `fallback.*`
// has its own visitor and its file scope still held none. A script, a `main.swift` or a
// playground page that bounds a value before converting it was reported as though it had
// not, and the repairs on offer were the same two: move it into a function, or inline it.

private func intConversionLines(_ source: String) -> [Int] {
    FallbackRules.audit(source: source, fileName: "Sources/Tool/main.swift")
        .diagnostics
        .filter { $0.ruleId == FallbackRuleID.intConversionUnguarded }
        .compactMap(\.lineNumber)
}

@Suite("fallback.int-conversion-unguarded: top-level code")
struct FallbackTopLevelTests {

    @Test("A guard at file scope bounds the conversion that follows it")
    func topLevelGuardBounds() {
        let code = """
        import Foundation
        let tenor: Double = readValue()
        guard tenor.isFinite, tenor >= 0, tenor < 1_000 else { exit(1) }
        let year = Int(tenor)
        print(year)
        """
        #expect(intConversionLines(code) == [])
    }

    @Test("Bounds asserted by a file-scope guard reject a NaN without isFinite")
    func topLevelAssertedBounds() {
        let code = """
        import Foundation
        let shape: Double = readValue()
        guard shape > 0, shape <= 1_000_000 else { exit(1) }
        print(Int(shape))
        """
        #expect(intConversionLines(code) == [])
    }

    @Test("A check inside a file-scope do block bounds the conversion beside it")
    func topLevelDoBlockBounds() {
        let code = """
        do {
            let tenor: Double = readValue()
            guard tenor.isFinite, tenor >= 0, tenor < 1_000 else { throw CancellationError() }
            print(Int(tenor))
        } catch {
            print("skipped")
        }
        """
        #expect(intConversionLines(code) == [])
    }

    @Test("An unbounded conversion at file scope is still reported")
    func topLevelUnboundedIsReported() {
        let code = """
        let tenor: Double = readValue()
        let year = Int(tenor)
        print(year)
        """
        #expect(intConversionLines(code) == [2])
    }

    @Test("A bound written after the conversion at file scope did not protect it")
    func topLevelBoundAfterIsReported() {
        let code = """
        import Foundation
        let tenor: Double = readValue()
        let year = Int(tenor)
        guard tenor.isFinite, tenor >= 0, tenor < 1_000 else { exit(1) }
        print(year)
        """
        #expect(intConversionLines(code) == [3])
    }

    @Test("A guard inside a function does not answer for file-scope code")
    func functionGuardDoesNotReachFileScope() {
        let code = """
        let tenor: Double = readValue()
        func whole(_ tenor: Double) -> Int {
            guard tenor.isFinite, tenor >= 0, tenor < 1_000 else { return 0 }
            return Int(tenor)
        }
        print(Int(tenor))
        """
        #expect(intConversionLines(code) == [6])
    }

    @Test("A guard inside a type's member does not answer for file-scope code")
    func memberGuardDoesNotReachFileScope() {
        let code = """
        let tenor: Double = readValue()
        struct Years {
            let value: Int
            init?(tenor: Double) {
                guard tenor.isFinite, tenor >= 0, tenor < 1_000 else { return nil }
                value = Int(tenor)
            }
        }
        print(Int(tenor))
        """
        #expect(intConversionLines(code) == [9])
    }
}
