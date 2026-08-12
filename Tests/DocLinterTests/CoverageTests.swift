import Foundation
import Testing
@testable import DocLinter
@testable import QualityGateCore

/// A checker that examined nothing and a checker that found nothing wrong must not print the
/// same thing.
///
/// `doc-lint` asked DocC about the first target of the first `.library` product and reported the
/// answer as the project's documentation verdict. On this package that was 1 target of 116 — not
/// degraded coverage but absent coverage, indistinguishable in the output from a clean run.
/// `doc-generated` had already learned this and prints its region count on every run; `doc-lint`
/// was written without it.
@Suite("Doc Lint: coverage")
struct CoverageTests {

    private static func project(catalogues: [String], spelling: String = "Sources") throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doclint-\(UUID().uuidString)")
        for module in catalogues {
            let directory = root.appendingPathComponent(spelling)
                .appendingPathComponent(module)
                .appendingPathComponent("\(module).docc")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("\(spelling)/Undocumented"),
            withIntermediateDirectories: true)
        return root
    }

    @Test("Every target owning a catalogue is enumerated, not just the first")
    func everyDocumentedTargetIsFound() throws {
        let root = try Self.project(catalogues: ["Alpha", "Beta", "Gamma"])
        defer { try? FileManager.default.removeItem(at: root) }

        let targets = DocLinter.documentedTargets(projectRoot: root.path)

        #expect(targets == ["Alpha", "Beta", "Gamma"])
        #expect(!targets.contains("Undocumented"))
    }

    @Test("Catalogues are found under `Source/` and `src/` too")
    func alternativeLayoutsAreFound() throws {
        for spelling in ["Source", "src"] {
            let root = try Self.project(catalogues: ["Alpha"], spelling: spelling)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(DocLinter.documentedTargets(projectRoot: root.path) == ["Alpha"])
        }
    }

    @Test("Examining nothing is an error, not a pass")
    func zeroCoverageIsAnError() {
        let diagnostic = DocLinter.coverageDiagnostic(explicit: nil, documented: [])

        #expect(diagnostic.severity == .error)
        #expect(diagnostic.ruleId == "doc-lint.no-coverage")
    }

    @Test("What was examined is reported on a normal run")
    func coverageIsReported() {
        let diagnostic = DocLinter.coverageDiagnostic(
            explicit: nil, documented: ["Alpha", "Beta"])

        #expect(diagnostic.severity == .note)
        #expect(diagnostic.message.contains("2"))
    }

    @Test("A configured `docTarget` narrows the run, and the note says so")
    func configuredTargetIsReportedAsNarrowing() {
        // The trap this repository fell into: `docTarget: QualityGateCore` in `.quality-gate.yml`
        // pinned the run to one module, and nothing in the output said the other 115 were never
        // handed to DocC. An explicit narrowing is legitimate; an invisible one is not.
        let diagnostic = DocLinter.coverageDiagnostic(
            explicit: "QualityGateCore", documented: Array(repeating: "M", count: 31))

        #expect(diagnostic.severity == .note)
        #expect(diagnostic.message.contains("QualityGateCore"))
        #expect(diagnostic.message.contains("31"))
    }
}
