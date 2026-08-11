import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// The checker's contract with the runner, and the coverage it is obliged to report whether
/// it passes or fails.
@Suite("Doc Generated Auditor")
struct DocGeneratedAuditorTests {

    // MARK: - Identity and contract

    @Test("Identity is the documented one")
    func identity() {
        let auditor = DocGeneratedAuditor()
        #expect(auditor.id == "doc-generated")
        #expect(auditor.name == "Generated Content Auditor")
    }

    @Test("Parallel-safe: a read and an in-memory regeneration, no build lock and no subprocess")
    func parallelSafe() {
        #expect(DocGeneratedAuditor().isParallelSafe)
    }

    @Test("Hermetic, which is precisely what buys it the authority to gate")
    func hermetic() {
        // `status`'s Last-Updated rule is clamped to `.note` because "is this stale?" is a
        // question about the calendar. "Does this table disagree with the tree?" is a
        // question about the tree alone, so it may block — and every generator is required
        // to read nothing but files under the project root in order to keep that true.
        #expect(DocGeneratedAuditor().hermeticity == .hermetic)
    }

    @Test("Cache inputs name the governed documents, not only the sources they derive from")
    func cacheInputsIncludeGovernedDocuments() throws {
        let root = try TemporaryDocProject.make(
            readme: "# R\n", changelog: "# C\n", masterPlan: "# M\n", packageManifest: "// P\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let inputs = DocGeneratedAuditor.cacheInputs(
            projectRoot: root, configuration: TemporaryDocProject.configuration())

        let files = try #require(inputs?.files)
        #expect(files.contains { $0.hasSuffix("README.md") })
        #expect(files.contains { $0.hasSuffix("CHANGELOG.md") })
        #expect(files.contains { $0.hasSuffix("project/master_plan.md") })
        #expect(files.contains { $0.hasSuffix("Package.swift") })
    }

    // MARK: - Coverage is reported in every mode

    @Test("A project with no regions passes, and says so with a coverage line")
    func noRegionsIsAPassWithCoverage() async throws {
        let root = try TemporaryDocProject.make(
            readme: "# Readme\n", changelog: "# Changelog\n", masterPlan: "# Plan\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await DocGeneratedAuditor().check(
            projectRoot: root, configuration: TemporaryDocProject.configuration())

        #expect(result.status == .passed)
        let coverage = try #require(result.diagnostics.first { $0.ruleId == "doc-generated.coverage" })
        #expect(coverage.severity == .note)
        #expect(coverage.message.contains("0 found"))
    }

    @Test("The coverage line is printed when the run fails too — an under-reported gate reads as a passing one")
    func coverageIsReportedOnFailure() async throws {
        let root = try TemporaryDocProject.make(
            masterPlan: "<!-- generated:orphan -->\nbody\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await DocGeneratedAuditor().check(
            projectRoot: root, configuration: TemporaryDocProject.configuration())

        #expect(result.status == .failed)
        #expect(result.diagnostics.contains { $0.ruleId == "doc-generated.coverage" })
    }

    // MARK: - Malformed regions fire

    @Test("An unterminated region fails the check at the governed file's own line")
    func unterminatedRegionIsAnError() async throws {
        let root = try TemporaryDocProject.make(
            masterPlan: "# Plan\n\n<!-- generated:module-structure -->\ncontent\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await DocGeneratedAuditor().check(
            projectRoot: root, configuration: TemporaryDocProject.configuration())

        let defect = try #require(result.diagnostics.first {
            $0.ruleId == "doc-generated.region-unterminated"
        })
        #expect(defect.severity == .error)
        #expect(defect.lineNumber == 3)
        #expect(defect.filePath?.hasSuffix("project/master_plan.md") == true)
    }

    @Test("An id with no registered generator is an error, never a silent skip")
    func unknownIDIsAnError() async throws {
        // A misspelled id that scanned clean and then checked nothing would be the worst
        // possible outcome: a region that reads as governed and is not.
        let root = try TemporaryDocProject.make(
            masterPlan: "<!-- generated:no-such-id -->\n<!-- /generated:no-such-id -->\n")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await DocGeneratedAuditor().check(
            projectRoot: root, configuration: TemporaryDocProject.configuration())

        let unknown = try #require(result.diagnostics.first {
            $0.ruleId == "doc-generated.region-unknown-id"
        })
        #expect(unknown.severity == .error)
        #expect(result.status == .failed)
    }

    // MARK: - Self-contradiction, which needs no generator

    @Test("A document that disagrees with itself fails with no generator involved")
    func selfContradictionFires() async throws {
        let root = try TemporaryDocProject.make(masterPlan: """
        ### What's Working
        - [ ] XcodeReporter — `--format xcode` for Xcode Build Phase inline annotations

        ### Phase 4
        - [x] XcodeReporter — `--format xcode` output for Xcode Build Phase inline annotations
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await DocGeneratedAuditor().check(
            projectRoot: root, configuration: TemporaryDocProject.configuration())

        let finding = try #require(result.diagnostics.first {
            $0.ruleId == "doc-generated.self-contradiction"
        })
        #expect(finding.severity == .error)
        #expect(finding.lineNumber == 2)
        #expect(finding.message.contains("XcodeReporter"))
        #expect(result.status == .failed)
    }

    // MARK: - Severity

    @Test("No finding is ever a note except the coverage line")
    func findingsAreNeverNotes() async throws {
        // `Adopt.swift` filters the baseline scan with `severity != .note`, so a note is
        // structurally excluded from the ledger. A rule reported at `.note` could never be
        // adopted, and therefore could never come due.
        let root = try TemporaryDocProject.make(masterPlan: """
        <!-- generated:no-such-id -->
        <!-- /generated:no-such-id -->
        - [ ] Alpha — open
        - [x] Alpha — done
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await DocGeneratedAuditor().check(
            projectRoot: root, configuration: TemporaryDocProject.configuration())

        let substantive = result.diagnostics.filter { $0.ruleId != "doc-generated.coverage" }
        #expect(!substantive.isEmpty)
        #expect(substantive.allSatisfy { $0.severity != .note })
    }

    // MARK: - Scope

    @Test("A governed file excluded from scanning is counted, so the gap is visible")
    func excludedFilesAreCountedNotHidden() async throws {
        let root = try TemporaryDocProject.make(masterPlan: """
        <!-- generated:no-such-id -->
        <!-- /generated:no-such-id -->
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await DocGeneratedAuditor().check(
            projectRoot: root,
            configuration: TemporaryDocProject.configuration(excludePatterns: ["project/"]))

        #expect(!result.diagnostics.contains { $0.ruleId == "doc-generated.region-unknown-id" })
        let coverage = try #require(result.diagnostics.first { $0.ruleId == "doc-generated.coverage" })
        #expect(coverage.message.contains("not scanned"))
    }

    @Test("Configured additional files are scanned as well — the knob widens and never narrows")
    func additionalFilesAreScanned() async throws {
        let root = try TemporaryDocProject.make(
            extras: ["docs/guide.md": "<!-- generated:no-such-id -->\n<!-- /generated:no-such-id -->\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await DocGeneratedAuditor().check(
            projectRoot: root,
            configuration: TemporaryDocProject.configuration(
                docGenerated: DocGeneratedConfig(additionalFiles: ["docs/guide.md"])))

        #expect(result.diagnostics.contains { $0.ruleId == "doc-generated.region-unknown-id" })
    }
}
