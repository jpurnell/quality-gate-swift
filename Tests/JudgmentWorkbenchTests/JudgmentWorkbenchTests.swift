import Foundation
import Testing
import CorpusKit
import QualityGateCore
import IdiomAuditor
import SmellPack
import GatePlugins
import JudgmentWorkbench

// The golden half of the JudgmentWorkbench suite. The sources, and the unit tests over the
// rule registry, the marker text surgery and inbox extraction, moved to
// quality-gate-corpus-kit 1.18.0 on 2026-09-18.
//
// These stayed because they are the only tests that can prove the thing worth proving: that
// the marker `MarkerWriter` writes is the one `IdiomAuditor`, `SmellPack` and
// `CustomRulesChecker` actually honour on the next run. Each drives a real auditor over a real
// file, acknowledges the finding through the inbox, and re-audits. Moving them with the
// sources would have meant asserting the convention against a copy of itself; the auditors
// live here, so the proof does.
//
// `@testable` is now a plain `import`: the module is external, and everything these reach is
// public API — which is itself a small check that the move did not quietly widen anything.


// MARK: - Shared fixtures

/// Builds a minimal `CheckResultMetadata` wrapping the given checker results.
private func makeMetadata(results: [CheckResult]) -> CheckResultMetadata {
    CheckResultMetadata(
        projectID: "judgment-workbench-tests",
        timestamp: Date(timeIntervalSince1970: 0),
        environment: .local,
        decisionOwner: "tester",
        results: results,
        overrides: [],
        riskTier: .informational,
        ethicalFlags: [],
        consistencyScore: nil
    )
}

/// Creates a unique temp directory and returns its URL.
private func makeTempDirectory(prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - Golden re-audit: acknowledge turns a finding into an override

@Suite("Golden re-audit", .serialized)
struct GoldenReAuditTests {

    @Test("idiom finding acknowledged from the inbox disappears on re-audit and records an override")
    func idiomRoundTrip() async throws {
        let root = try makeTempDirectory(prefix: "golden-idiom")
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort temp cleanup
        let sources = root.appendingPathComponent("Sources/ModA", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("A.swift")
        try "let flag = [1].count == 0\n".write(to: file, atomically: true, encoding: .utf8)

        let auditor = IdiomAuditor(root: root.path)
        let before = try await auditor.check(configuration: Configuration())
        #expect(before.diagnostics.map(\.ruleId) == ["idiom.empty-count"])
        #expect(before.overrides.isEmpty)

        let items = FindingsInbox.items(from: makeMetadata(results: [before]))
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.ruleId == "idiom.empty-count")
        #expect(item.lineNumber == 1)
        try FindingsInbox.acknowledge(item: item, reason: "count comparison is clearer here")

        let after = try await auditor.check(configuration: Configuration())
        #expect(after.diagnostics.isEmpty)
        #expect(after.overrides.count == 1)
        let override = try #require(after.overrides.first)
        #expect(override.ruleId == "idiom.empty-count")
        #expect(override.justification == "// idiom:exempt")
        #expect(override.lineNumber == 1)
    }

    @Test("smell finding acknowledged from the inbox disappears on re-audit and records an override")
    func smellRoundTrip() async throws {
        let root = try makeTempDirectory(prefix: "golden-smell")
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort temp cleanup
        let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("Wide.swift")
        try "func wide(a: Int, b: Int, c: Int, d: Int, e: Int, g: Int) -> Int { a }\n"
            .write(to: file, atomically: true, encoding: .utf8)

        let checker = SmellPack(root: root.path)
        let before = try await checker.check(configuration: Configuration())
        #expect(before.diagnostics.map(\.ruleId) == ["smell.parameter-count"])
        #expect(before.overrides.isEmpty)

        let items = FindingsInbox.items(from: makeMetadata(results: [before]))
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.ruleId == "smell.parameter-count")
        #expect(item.lineNumber == 1)
        try FindingsInbox.acknowledge(item: item, reason: nil)

        let after = try await checker.check(configuration: Configuration())
        #expect(after.diagnostics.isEmpty)
        #expect(after.overrides.count == 1)
        let override = try #require(after.overrides.first)
        #expect(override.ruleId == "smell.parameter-count")
        #expect(override.justification == "// smell:exempt")
        #expect(override.lineNumber == 1)
    }

    @Test("custom rule finding acknowledged from the inbox disappears on re-audit and records an override")
    func customRuleRoundTrip() async throws {
        let root = try makeTempDirectory(prefix: "golden-custom")
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort temp cleanup
        let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("Printy.swift")
        try "print(\"hello\")\n".write(to: file, atomically: true, encoding: .utf8)

        let rule = CustomRuleConfig(
            id: "no-print", pattern: "print\\(", message: "Use os.Logger", severity: .note)
        let checker = CustomRulesChecker(root: root.path)
        let configuration = Configuration(customRules: [rule])

        let before = try await checker.check(configuration: configuration)
        #expect(before.diagnostics.map(\.ruleId) == ["no-print"])
        #expect(before.diagnostics.map(\.origin) == ["custom-rule"])

        let items = FindingsInbox.items(from: makeMetadata(results: [before]))
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.marker?.marker == "// custom:exempt")
        try FindingsInbox.acknowledge(item: item, reason: "CLI tool output, not diagnostics")

        let after = try await checker.check(configuration: configuration)
        #expect(after.diagnostics.isEmpty)
        #expect(after.overrides.count == 1)
        let override = try #require(after.overrides.first)
        #expect(override.ruleId == "no-print")
        #expect(override.justification == "// custom:exempt")
        #expect(override.lineNumber == 1)
    }
}
