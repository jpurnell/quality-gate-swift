import Foundation
import Testing
@testable import QualityGateCore
@testable import SafetyAuditor

/// `// SAFETY:` silences a finding and leaves a record that it did.
///
/// It was the most-written marker in the portfolio and recorded nothing: a call site in the
/// visitor carried the comment "SAFETY comment suppresses without creating override".
@Suite("safety: markers are recorded")
struct SafetySuppressionRecordingTests {

    private func audit(_ code: String, configuration: Configuration = Configuration()) async throws -> CheckResult {
        try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: configuration)
    }

    @Test("A force-try under a token-reason `// SAFETY:` is recorded as a suppression")
    func forceTryTokenReason() async throws {
        // IconquerGameKit, GameViewModel.swift:318
        let code = """
        func placeholder() -> Game {
            return try! Game.start(  // SAFETY: placeholder with known-good inputs
                seed: 0)
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "force-try" }.isEmpty)

        let records = result.overrides.map(SuppressionRecord.init)
        #expect(records.count == 1)
        #expect(records[0].kind == .suppressed)
        #expect(records[0].form == "// SAFETY:")
        #expect(records[0].ruleId == "force-try")
        #expect(records[0].lineNumber == 2)
        #expect(records[0].markerLine == 2)
        #expect(records[0].reason == "placeholder with known-good inputs")
        #expect(records[0].rejection == "4 words, 8 required")
    }

    @Test("A marker on the line above with a reason that validates is an acknowledgement")
    func forceUnwrapValidatedReasonAbove() async throws {
        let code = """
        func first(_ xs: [Int]) -> Int {
            // SAFETY: the caller checked isEmpty on the line above and returned early if so
            return xs.first!
        }
        """
        let records = try await audit(code).overrides.map(SuppressionRecord.init)
        #expect(records.count == 1)
        #expect(records[0].kind == .acknowledged)
        #expect(records[0].validator == "reason-quality")
        #expect(records[0].ruleId == "force-unwrap")
        #expect(records[0].lineNumber == 3)
        #expect(records[0].markerLine == 2)
    }

    @Test("Without the marker the finding is raised and nothing is recorded")
    func noMarkerNoRecord() async throws {
        let code = """
        func first(_ xs: [Int]) -> Int {
            return xs.first!
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "force-unwrap" }.map(\.lineNumber) == [2])
        #expect(result.overrides.isEmpty)
    }

    @Test("A marker beside code that raises no finding is not recorded")
    func decorativeMarker() async throws {
        let code = """
        func first(_ xs: [Int]) -> Int? {
            return xs.first // SAFETY: nothing here needs excusing at all
        }
        """
        let result = try await audit(code)
        #expect(result.overrides.isEmpty)
    }

    @Test("One marker over two findings on a line records both, against the same marker line")
    func oneMarkerTwoFindings() async throws {
        let code = """
        func pair(_ a: Int?, _ b: Int?) -> Int {
            return a! + b! // SAFETY: both were validated by the parser that produced this node
        }
        """
        let records = try await audit(code).overrides.map(SuppressionRecord.init)
        #expect(records.map(\.ruleId) == ["force-unwrap", "force-unwrap"])
        #expect(records.map(\.markerLine) == [2, 2])
        #expect(SuppressionLedger(results: [try await audit(code)]).overall.acknowledged == 2)
    }

    @Test("A configured exemption pattern is the form that is recorded")
    func configuredPattern() async throws {
        let code = """
        func first(_ xs: [Int]) -> Int {
            return xs.first! // OK: checked
        }
        """
        let result = try await audit(code, configuration: Configuration(safetyExemptions: ["// OK:"]))
        let records = result.overrides.map(SuppressionRecord.init)
        #expect(records.map(\.form) == ["// OK:"])
        #expect(records.first?.reason == "checked")
    }

    @Test("`// SECURITY:` is recorded as an acknowledgement naming the enforced validator")
    func securityAcknowledgement() async throws {
        let code = """
        import Foundation
        func run(_ command: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // SECURITY: the command is assembled from a fixed table of maintenance scripts, never from input
            process.arguments = ["-c", "echo " + command]
            try process.run()
        }
        """
        let config = Configuration(security: SecurityAuditorConfig(enabledRules: ["security.command-injection"]))
        let result = try await audit(code, configuration: config)
        let records = result.overrides.map(SuppressionRecord.init).filter { $0.form == "// SECURITY:" }
        #expect(records.count == 1)
        #expect(records.first?.kind == .acknowledged)
        #expect(records.first?.validator == "justification-validator")
        #expect(records.first?.ruleId == "security.command-injection")
        #expect(records.first?.forwardedToCorpus == true)
        #expect(records.first?.reason
            == "the command is assembled from a fixed table of maintenance scripts, never from input")
    }
}
