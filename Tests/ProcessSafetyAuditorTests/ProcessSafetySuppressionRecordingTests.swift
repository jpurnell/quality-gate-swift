import Foundation
import Testing
@testable import ProcessSafetyAuditor
@testable import QualityGateCore

/// `// process-safety:disable` silences a finding and leaves a record that it did.
@Suite("process-safety: markers are recorded")
struct ProcessSafetySuppressionRecordingTests {

    private static let deadlock = """
        import Foundation
        func run() throws -> Data {
            let process = Process()
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()MARKER
            return pipe.fileHandleForReading.readDataToEndOfFile()
        }
        """

    @Test("The marker silences wait-before-read and is recorded as a suppression")
    func markerIsRecorded() {
        let source = Self.deadlock.replacingOccurrences(of: "MARKER", with: " // process-safety:disable")
        let audit = ProcessSafetyAuditor().auditSourceRecordingMarkers(source, fileName: "Test.swift")
        #expect(audit.diagnostics.isEmpty)

        let records = audit.overrides.map(SuppressionRecord.init)
        #expect(records.count == 1)
        #expect(records[0].kind == .suppressed)
        #expect(records[0].form == "// process-safety:disable")
        #expect(records[0].ruleId == "process.wait-before-read")
        #expect(records[0].lineNumber == 7)
        #expect(records[0].markerLine == 7)
        #expect(records[0].rejection == "no reason given")
    }

    @Test("Without the marker the deadlock is reported and nothing is recorded")
    func noMarker() {
        let source = Self.deadlock.replacingOccurrences(of: "MARKER", with: "")
        let audit = ProcessSafetyAuditor().auditSourceRecordingMarkers(source, fileName: "Test.swift")
        #expect(audit.diagnostics.map(\.ruleId) == ["process.wait-before-read"])
        #expect(audit.diagnostics.map(\.lineNumber) == [7])
        #expect(audit.overrides.isEmpty)
    }

    @Test("The diagnostics-only entry point is unchanged by recording")
    func legacyEntryPoint() {
        let source = Self.deadlock.replacingOccurrences(of: "MARKER", with: "")
        #expect(ProcessSafetyAuditor().auditSource(source, fileName: "Test.swift").count == 1)
    }
}
