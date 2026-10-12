import Foundation
import Testing
@testable import BoundedIOAuditor
@testable import QualityGateCore

/// A site acknowledged with `// Unbounded:` is listed, not only counted.
@Suite("bounded-io: acknowledgements are recorded")
struct BoundedIOSuppressionRecordingTests {

    @Test("A reasoned `// Unbounded:` is recorded with its reason and both lines")
    func reasonedAcknowledgement() {
        // CoverLetterWriter, EditorIntegration.swift:63
        let source = """
        func edit(_ process: Process) throws {
            try process.run()
            // Unbounded: the bound is the user finishing their edit. No honest deadline exists for a person typing.
            process.waitUntilExit()
        }
        """
        let scan = BoundedIOAuditor.scan(source: source, fileName: "/p/Sources/X/X.swift")
        #expect(scan.diagnostics.isEmpty)
        #expect(scan.acknowledged == 1)

        let records = scan.overrides.map(SuppressionRecord.init)
        #expect(records.count == 1)
        #expect(records[0].kind == .acknowledged)
        #expect(records[0].form == "// Unbounded:")
        #expect(records[0].ruleId == "bounded-io.outside-kernel")
        #expect(records[0].lineNumber == 4)
        #expect(records[0].markerLine == 3)
    }

    @Test("A two-word reason satisfies the marker and is recorded as a suppression")
    func thinReason() {
        let source = """
        func edit(_ process: Process) {
            // Unbounded: see above
            process.waitUntilExit()
        }
        """
        let scan = BoundedIOAuditor.scan(source: source, fileName: "/p/Sources/X/X.swift")
        let records = scan.overrides.map(SuppressionRecord.init)
        #expect(scan.diagnostics.isEmpty)
        #expect(records.map(\.kind) == [.suppressed])
        #expect(records.first?.rejection == "2 words, 8 required")
    }

    @Test("A bare marker acknowledges nothing: the finding stands and nothing is recorded")
    func bareMarker() {
        let source = """
        func edit(_ process: Process) {
            // Unbounded:
            process.waitUntilExit()
        }
        """
        let scan = BoundedIOAuditor.scan(source: source, fileName: "/p/Sources/X/X.swift")
        #expect(scan.diagnostics.map(\.ruleId) == ["bounded-io.outside-kernel"])
        #expect(scan.overrides.isEmpty)
    }
}
