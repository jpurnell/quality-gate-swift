import Foundation
import Testing
@testable import LoggingAuditor
@testable import QualityGateCore

/// `// silent:` and `// logging:` silence a finding and leave a record that they did.
///
/// From June 2026 they silenced without one — a commit titled "Eliminate all override
/// records" made the override count read zero by no longer counting. The fixtures are the
/// shapes that were then sitting unrecorded across the portfolio.
@Suite("logging: markers are recorded")
struct LoggingSuppressionRecordingTests {

    private func records(_ code: String, projectType: String = "application") async throws -> [SuppressionRecord] {
        try await TestHelpers.audit(code, projectType: projectType).overrides.map(SuppressionRecord.init)
    }

    @Test("`// silent:` with a token reason silences the finding and is recorded as a suppression")
    func silentTokenReason() async throws {
        // BioFeedbackKit-HealthKit, HKHealthStoreAdapter.swift:204
        let code = """
        import os
        func end(_ oldBuilder: Builder) async {
            try? await oldBuilder.endCollection(at: Date()) // silent: best-effort cleanup of previous session builder
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "logging.silent-try" }.isEmpty)

        let records = result.overrides.map(SuppressionRecord.init)
        #expect(records.count == 1)
        #expect(records[0].kind == .suppressed)
        #expect(records[0].form == "// silent:")
        #expect(records[0].ruleId == "logging.silent-try")
        #expect(records[0].lineNumber == 3)
        #expect(records[0].markerLine == 3)
        #expect(records[0].reason == "best-effort cleanup of previous session builder")
        #expect(records[0].rejection == "6 words, 8 required")
        #expect(records[0].filePath == "test.swift")
        #expect(records[0].forwardedToCorpus == false)
    }

    @Test("`// silent:` on the line above with a reason that validates is an acknowledgement")
    func silentValidatedReasonAbove() async throws {
        let code = """
        import os
        func load(_ path: String) -> String? {
            // silent: a missing settings file is the ordinary first-run case and the caller supplies defaults
            try? String(contentsOfFile: path, encoding: .utf8)
        }
        """
        let records = try await records(code)
        #expect(records.count == 1)
        #expect(records[0].kind == .acknowledged)
        #expect(records[0].validator == "reason-quality")
        #expect(records[0].lineNumber == 4)
        #expect(records[0].markerLine == 3)
    }

    @Test("Without the marker the finding is raised and nothing is recorded")
    func noMarkerNoRecord() async throws {
        let code = """
        import os
        func end(_ oldBuilder: Builder) async {
            try? await oldBuilder.endCollection(at: Date())
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "logging.silent-try" }.map(\.lineNumber) == [3])
        #expect(result.overrides.isEmpty)
    }

    @Test("A marker beside a `try?` that raises no finding is not recorded as silencing one")
    func decorativeMarkerIsNotRecorded() async throws {
        // `Task.sleep` is on the default allow-list, so there is no finding for the marker
        // to silence. A record here would count a suppression that never happened.
        let code = """
        import os
        func pause() async {
            try? await Task.sleep(nanoseconds: 1) // silent: best effort
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "logging.silent-try" }.isEmpty)
        #expect(result.overrides.isEmpty)
    }

    @Test("`// logging:` records the rule it silenced, for each of the rules it can silence")
    func loggingMarkerPerRule() async throws {
        // IconquerServer: WebSocketServer.swift:263 and TurnTimer.swift:31; BusinessMath
        // BusinessMathLogger.swift:206.
        let code = """
        import os
        let logger = Logger(subsystem: "s", category: "c")
        func connected(_ id: String) {
            logger.debug("WebSocket connected: \\(id)") // logging: connection IDs are server-generated UUIDs
        }
        func tick() async {
            do {
                try await Task.sleep(nanoseconds: 1)
            } catch { // logging: Task.sleep cancellation is expected during normal room cleanup
            }
        }
        func emit(_ line: String) {
            print(line) // logging: this type is the console sink the logger itself writes through
        }
        """
        let result = try await TestHelpers.audit(code)
        let silenced: Set<String> = [
            "logging.missing-privacy", "logging.catch-without-logging", "logging.print-statement",
        ]
        #expect(result.diagnostics.filter { silenced.contains($0.ruleId ?? "") }.isEmpty)

        let records = result.overrides.map(SuppressionRecord.init)
        #expect(records.map(\.ruleId) == [
            "logging.missing-privacy", "logging.catch-without-logging", "logging.print-statement",
        ])
        #expect(records.map(\.form) == ["// logging:", "// logging:", "// logging:"])
        #expect(records.map(\.lineNumber) == [4, 9, 13])
        #expect(records.map(\.kind) == [.suppressed, .acknowledged, .acknowledged])
        #expect(records[0].rejection == "5 words, 8 required")
    }

    @Test("A `// logging:` marker beside a call that is already annotated is not recorded")
    func loggingMarkerBesideCleanCall() async throws {
        let code = """
        import os
        let logger = Logger(subsystem: "s", category: "c")
        func connected(_ id: String) {
            logger.debug("WebSocket connected: \\(id, privacy: .public)") // logging: ids are public
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.overrides.isEmpty)
    }

    @Test("A configured silent keyword is the form that is recorded")
    func configuredKeyword() async throws {
        let code = """
        import os
        func end(_ b: Builder) async {
            try? await b.finish() // quiet: nothing to do
        }
        """
        let result = try await TestHelpers.audit(code, silentTryKeyword: "quiet:")
        let records = result.overrides.map(SuppressionRecord.init)
        #expect(records.map(\.form) == ["// quiet:"])
        #expect(records.first?.reason == "nothing to do")
    }
}
