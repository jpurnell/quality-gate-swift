import Foundation
import Testing
import QualityGateCore
@testable import SafetyAuditor

/// End-to-end proof of the root artery: a checker pointed via
/// `Configuration.projectRoot` at a fixture tree reports on *that* tree while the
/// process working directory is somewhere else entirely.
///
/// One checker, not forty-six: the per-checker edits are mechanical substitutions once
/// the artery exists, and each checker's own tests keep passing through the lazy cwd
/// fallback. This test is the one that fails if the artery itself regresses.
/// See `project/plans/proposals/CheckerRootThreading.md` §4.
@Suite("Project root end-to-end")
struct ProjectRootEndToEndTests {

    @Test("SafetyAuditor audits the configured root, not the process cwd")
    func auditsConfiguredRootNotCwd() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-root-e2e-\(UUID().uuidString)")
        let sources = fixtureRoot.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        // A force unwrap the auditor must find — in the fixture, not in this repository.
        try """
        let values: [Int] = [1, 2, 3]
        let first = values.first!
        """.write(to: sources.appendingPathComponent("bad.swift"), atomically: true, encoding: .utf8)

        var configuration = Configuration()
        configuration.projectRoot = fixtureRoot

        // The process cwd is this repository (the test runner's checkout); the fixture
        // is under the temporary directory. If the auditor read cwd it would scan the
        // gate's own (clean) sources and find nothing at the fixture's path.
        let result = try await SafetyAuditor().check(configuration: configuration)

        let fixtureFindings = result.diagnostics.filter {
            ($0.filePath ?? "").hasPrefix(fixtureRoot.path)
        }
        #expect(fixtureFindings.contains { ($0.ruleId ?? "").contains("force-unwrap") },
                "expected the fixture's force unwrap to be found; got: \(result.diagnostics.map { ($0.ruleId ?? "?", $0.filePath ?? "?") })")
    }
}
