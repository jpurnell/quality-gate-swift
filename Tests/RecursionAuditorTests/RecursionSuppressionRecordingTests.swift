import Foundation
import Testing
@testable import QualityGateCore
@testable import RecursionAuditor

/// `// recursion:safe` silences a finding and leaves a record that it did.
@Suite("recursion: markers are recorded")
struct RecursionSuppressionRecordingTests {

    private func audit(_ code: String) async throws -> CheckResult {
        var config = Configuration()
        config.recursion.useIndexStore = false
        return try await RecursionAuditor().auditSource(code, fileName: "test.swift", configuration: config)
    }

    @Test("A bare marker on an unconditional self-call is a suppression with no reason")
    func bareMarkerOnSelfCall() async throws {
        // sicp-swift-companion, Section_1_1_7_SquareRoots.swift:59
        let code = """
        func sqrtIter(_ guess: Double) -> Double { // recursion:safe
            goodEnough(guess) ? guess : sqrtIter(improve(guess))
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "recursion.unconditional-self-call" }.isEmpty)

        let records = result.overrides.map(SuppressionRecord.init)
        #expect(records.count == 1)
        #expect(records[0].kind == .suppressed)
        #expect(records[0].form == "// recursion:safe")
        #expect(records[0].ruleId == "recursion.unconditional-self-call")
        #expect(records[0].lineNumber == 1)
        #expect(records[0].markerLine == 1)
        #expect(records[0].rejection == "no reason given")
    }

    @Test("Without the marker the same function is reported and nothing is recorded")
    func noMarker() async throws {
        let code = """
        func sqrtIter(_ guess: Double) -> Double {
            goodEnough(guess) ? guess : sqrtIter(improve(guess))
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "recursion.unconditional-self-call" }.map(\.lineNumber) == [1])
        #expect(result.overrides.isEmpty)
    }

    @Test("A marker on a function that does not recurse is not recorded")
    func decorativeMarker() async throws {
        let code = """
        func improve(_ guess: Double) -> Double { // recursion:safe
            guess / 2
        }
        """
        #expect(try await audit(code).overrides.isEmpty)
    }

    @Test("A marker on a guarded recursion — which is not a finding — is not recorded")
    func markerOnGuardedRecursion() async throws {
        let code = """
        func countdown(_ n: Int) -> Int { // recursion:safe
            guard n > 0 else { return 0 }
            return countdown(n - 1)
        }
        """
        #expect(try await audit(code).overrides.isEmpty)
    }

    @Test("A marker on a self-referencing computed property records that rule")
    func computedProperty() async throws {
        let code = """
        struct Foo {
            var value: Int { value + 1 } // recursion:safe — resolved through a property wrapper at runtime in this module
        }
        """
        let records = try await audit(code).overrides.map(SuppressionRecord.init)
        #expect(records.map(\.ruleId) == ["recursion.computed-property-self"])
        #expect(records.map(\.kind) == [.acknowledged])
    }
}
