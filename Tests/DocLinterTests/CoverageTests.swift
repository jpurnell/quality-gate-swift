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

/// A catalogue excluded from its target's `sourceFiles` is never handed to DocC.
///
/// `exclude:` quiets SwiftPM's unhandled-file warning, and swift-docc-plugin locates a catalogue
/// *through* `sourceFiles` — so the target is passed to DocC, DocC finds no articles for it, and
/// doc-lint reports a pass over documentation it never opened. Found 2026-08-27 in this package:
/// 34 of 35 catalogues were declared that way, and the coverage note said 35 the whole time.
/// Verified by injecting the same broken symbol link into two catalogues, one declared each way,
/// and running the gate once: only the declared one was reported.
@Suite("Doc Lint: excluded catalogues")
struct ExcludedCatalogueTests {

    private static func manifest(excluding: [String] = [], declaring: [String] = []) -> String {
        var targets: [String] = []
        for name in excluding {
            targets.append("""
                    .target(
                        name: "\(name)",
                        exclude: ["\(name).docc"]
                    ),
            """)
        }
        for name in declaring {
            targets.append("""
                    .target(
                        name: "\(name)",
                        resources: [.copy("\(name).docc")]
                    ),
            """)
        }
        return "let package = Package(\n    targets: [\n" + targets.joined(separator: "\n") + "\n    ]\n)"
    }

    @Test("A catalogue excluded from its target is detected")
    func excludedCatalogueIsDetected() {
        let manifest = Self.manifest(excluding: ["Alpha"])
        let withheld = DocLinter.cataloguesWithheldFromDocC(
            packageContent: manifest, documented: ["Alpha"])
        #expect(withheld == ["Alpha"])
    }

    @Test("A catalogue declared as a resource is not detected")
    func declaredCatalogueIsNotDetected() {
        let manifest = Self.manifest(declaring: ["Alpha"])
        let withheld = DocLinter.cataloguesWithheldFromDocC(
            packageContent: manifest, documented: ["Alpha"])
        #expect(withheld.isEmpty)
    }

    @Test("Only the excluded targets are named when a package mixes both")
    func mixedManifestNamesOnlyTheExcluded() {
        let manifest = Self.manifest(excluding: ["Alpha", "Gamma"], declaring: ["Beta"])
        let withheld = DocLinter.cataloguesWithheldFromDocC(
            packageContent: manifest, documented: ["Alpha", "Beta", "Gamma"])
        #expect(withheld == ["Alpha", "Gamma"])
    }

    @Test("A target excluding something other than its catalogue is not detected")
    func unrelatedExclusionIsNotDetected() {
        let manifest = """
        let package = Package(
            targets: [
                .target(
                    name: "Alpha",
                    exclude: ["NOTES.md"],
                    resources: [.copy("Alpha.docc")]
                ),
            ]
        )
        """
        let withheld = DocLinter.cataloguesWithheldFromDocC(
            packageContent: manifest, documented: ["Alpha"])
        #expect(withheld.isEmpty)
    }

    @Test("Each withheld catalogue is a warning naming the fix")
    func withheldCataloguesAreReported() {
        let diagnostics = DocLinter.withheldCatalogueDiagnostics(["Alpha", "Gamma"])
        #expect(diagnostics.count == 2)
        #expect(diagnostics.allSatisfy { $0.severity == .warning })
        #expect(diagnostics.allSatisfy { $0.ruleId == "doc-lint.catalogue-excluded" })
        #expect(diagnostics.contains { $0.message.contains("Alpha") })
        #expect(diagnostics.contains { ($0.suggestedFix ?? "").contains("resources:") })
    }

    @Test("The coverage note separates what was passed from what was withheld")
    func coverageNoteReportsWithheld() {
        let diagnostic = DocLinter.coverageDiagnostic(
            explicit: nil, documented: ["Alpha", "Beta"], withheld: ["Alpha"])
        #expect(diagnostic.severity == .note)
        #expect(diagnostic.message.contains("2"))
        #expect(diagnostic.message.contains("1"))
    }

    @Test("With nothing withheld the note makes no claim about exclusions")
    func cleanCoverageNoteIsUnchanged() {
        let diagnostic = DocLinter.coverageDiagnostic(
            explicit: nil, documented: ["Alpha", "Beta"], withheld: [])
        #expect(!diagnostic.message.lowercased().contains("withheld"))
        #expect(!diagnostic.message.lowercased().contains("exclud"))
    }
}

/// A manifest comment is not a manifest declaration.
///
/// Found in the wild the day the rule shipped: `SwiftMCPServer`'s Package.swift carries a
/// comment reading "DO NOT add `exclude: [\"SwiftMCPServer.docc\"]` here", with a paragraph
/// explaining that excluding a catalogue silently empties the documentation. The detector read
/// the comment as the thing it warns against and reported the target as withheld — a finding
/// that was exactly backwards, against a repository that had already diagnosed the problem
/// more thoroughly than the checker does.
@Suite("Doc Lint: manifest comments are not declarations")
struct ManifestCommentTests {

    @Test("A line comment mentioning exclude: is not an exclusion")
    func lineCommentIsNotAnExclusion() {
        let manifest = """
        let package = Package(
            targets: [
                .target(
                    name: "Alpha"
                    // DO NOT add `exclude: ["Alpha.docc"]` here — it silently empties the docs.
                ),
            ]
        )
        """
        #expect(DocLinter.cataloguesWithheldFromDocC(
            packageContent: manifest, documented: ["Alpha"]).isEmpty)
    }

    @Test("A block comment mentioning exclude: is not an exclusion")
    func blockCommentIsNotAnExclusion() {
        let manifest = """
        let package = Package(
            targets: [
                /* exclude: ["Alpha.docc"] was tried here and made doc-lint vacuous */
                .target(name: "Alpha"),
            ]
        )
        """
        #expect(DocLinter.cataloguesWithheldFromDocC(
            packageContent: manifest, documented: ["Alpha"]).isEmpty)
    }

    @Test("A real exclusion is still detected when a comment also mentions one")
    func realExclusionSurvivesNearbyComment() {
        let manifest = """
        let package = Package(
            targets: [
                // exclude: ["Beta.docc"] would be wrong for Beta
                .target(name: "Alpha", exclude: ["Alpha.docc"]),
            ]
        )
        """
        #expect(DocLinter.cataloguesWithheldFromDocC(
            packageContent: manifest, documented: ["Alpha", "Beta"]) == ["Alpha"])
    }
}
