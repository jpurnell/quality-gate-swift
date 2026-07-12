import Foundation
import Testing
import CorpusKit
import QualityGateCore
import IdiomAuditor
import SmellPack
import GatePlugins
@testable import JudgmentWorkbench

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

/// Wraps diagnostics in a single passed `CheckResult`.
private func makeResult(checkerId: String = "test-checker", diagnostics: [Diagnostic]) -> CheckResult {
    CheckResult(
        checkerId: checkerId,
        status: .passed,
        diagnostics: diagnostics,
        duration: .zero
    )
}

/// Creates a unique temp directory and returns its URL.
private func makeTempDirectory(prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// MARK: - AcknowledgeableRule registry

@Suite("AcknowledgeableRule registry")
struct AcknowledgeableRuleTests {

    @Test("idiom.* rules map to the end-of-line idiom:exempt marker")
    func idiomRule() throws {
        let rule = try #require(AcknowledgeableRule.for(ruleId: "idiom.empty-count", origin: nil))
        #expect(rule.marker == "// idiom:exempt")
        #expect(rule.requiresReason == false)
        #expect(rule.placement == .endOfLine)
    }

    @Test("smell.* rules map to the end-of-line smell:exempt marker")
    func smellRule() throws {
        let rule = try #require(AcknowledgeableRule.for(ruleId: "smell.parameter-count", origin: nil))
        #expect(rule.marker == "// smell:exempt")
        #expect(rule.requiresReason == false)
        #expect(rule.placement == .endOfLine)
    }

    @Test("custom-rule origin maps to the end-of-line custom:exempt marker regardless of rule id")
    func customRule() throws {
        let rule = try #require(AcknowledgeableRule.for(ruleId: "no-print", origin: "custom-rule"))
        #expect(rule.marker == "// custom:exempt")
        #expect(rule.requiresReason == false)
        #expect(rule.placement == .endOfLine)
    }

    @Test("legibility.over-public-symbol maps to legibility:reserved on the line above, reason required")
    func legibilityRule() throws {
        let rule = try #require(AcknowledgeableRule.for(ruleId: "legibility.over-public-symbol", origin: nil))
        #expect(rule.marker == "// legibility:reserved")
        #expect(rule.requiresReason == true)
        #expect(rule.placement == .lineAbove)
    }

    @Test("concurrency.cancellation-checkpoint-after-loop maps to end-of-line concurrency:exempt")
    func concurrencyRule() throws {
        let rule = try #require(AcknowledgeableRule.for(
            ruleId: "concurrency.cancellation-checkpoint-after-loop", origin: nil))
        #expect(rule.marker == "// concurrency:exempt")
        #expect(rule.requiresReason == false)
        #expect(rule.placement == .endOfLine)
    }

    @Test("rules without an acknowledgment path resolve to nil", arguments: [
        "safety.force-unwrap",
        "concurrency.unchecked-sendable",
        "legibility.module-cycle",
        "fp.division-guard",
    ])
    func unknownRules(ruleId: String) {
        #expect(AcknowledgeableRule.for(ruleId: ruleId, origin: nil) == nil)
    }
}

// MARK: - MarkerWriter

@Suite("MarkerWriter text surgery")
struct MarkerWriterTests {

    @Test("appends the marker end-of-line with a single space, preserving other lines")
    func appendsEndOfLine() throws {
        let source = "let a = 1\nlet flag = [1].count == 0\nlet b = 2\n"
        let updated = try MarkerWriter.apply(
            marker: "// idiom:exempt", reason: nil, toLine: 2, inSource: source)
        #expect(updated == "let a = 1\nlet flag = [1].count == 0 // idiom:exempt\nlet b = 2\n")
    }

    @Test("a reason is appended after the marker as comment continuation")
    func appendsReason() throws {
        let source = "let flag = [1].count == 0\n"
        let updated = try MarkerWriter.apply(
            marker: "// idiom:exempt", reason: "reviewed for clarity", toLine: 1, inSource: source)
        #expect(updated == "let flag = [1].count == 0 // idiom:exempt reviewed for clarity\n")
    }

    @Test("re-applying to a line that already carries the marker returns the source unchanged")
    func idempotent() throws {
        let source = "let flag = [1].count == 0 // idiom:exempt\n"
        let updated = try MarkerWriter.apply(
            marker: "// idiom:exempt", reason: nil, toLine: 1, inSource: source)
        #expect(updated == source)
    }

    @Test("a file without a trailing newline stays without one")
    func lastLineWithoutNewline() throws {
        let source = "let a = 1\nlet b = 2"
        let updated = try MarkerWriter.apply(
            marker: "// smell:exempt", reason: nil, toLine: 2, inSource: source)
        #expect(updated == "let a = 1\nlet b = 2 // smell:exempt")
    }

    @Test("line addressing is 1-based")
    func oneBasedIndexing() throws {
        let source = "first()\nsecond()\n"
        let updated = try MarkerWriter.apply(
            marker: "// custom:exempt", reason: nil, toLine: 1, inSource: source)
        #expect(updated == "first() // custom:exempt\nsecond()\n")
    }

    @Test("out-of-range lines throw a typed error", arguments: [0, 3, -1])
    func outOfRange(line: Int) {
        let source = "let a = 1\nlet b = 2\n"
        #expect(throws: MarkerWriterError.lineOutOfRange(line: line, lineCount: 2)) {
            _ = try MarkerWriter.apply(
                marker: "// idiom:exempt", reason: nil, toLine: line, inSource: source)
        }
    }

    @Test("CRLF line endings are preserved")
    func crlfPreserved() throws {
        let source = "let a = 1\r\nlet b = 2\r\n"
        let updated = try MarkerWriter.apply(
            marker: "// idiom:exempt", reason: nil, toLine: 1, inSource: source)
        #expect(updated == "let a = 1 // idiom:exempt\r\nlet b = 2\r\n")
    }

    @Test("trailing whitespace on the flagged line is trimmed so exactly one space precedes the marker")
    func trailingWhitespaceTrimmed() throws {
        let source = "let a = 1   \n"
        let updated = try MarkerWriter.apply(
            marker: "// idiom:exempt", reason: nil, toLine: 1, inSource: source)
        #expect(updated == "let a = 1 // idiom:exempt\n")
    }

    @Test("lineAbove placement inserts an indented comment line before the flagged line")
    func lineAbovePlacement() throws {
        let source = "import Foundation\n    public struct Helper {}\n"
        let updated = try MarkerWriter.apply(
            marker: "// legibility:reserved", reason: "downstream SPI surface",
            placement: .lineAbove, toLine: 2, inSource: source)
        #expect(updated == "import Foundation\n    // legibility:reserved downstream SPI surface\n    public struct Helper {}\n")
    }

    @Test("lineAbove placement is idempotent when the marker already precedes the line")
    func lineAboveIdempotent() throws {
        let source = "// legibility:reserved kept public\npublic struct Helper {}\n"
        let updated = try MarkerWriter.apply(
            marker: "// legibility:reserved", reason: "kept public",
            placement: .lineAbove, toLine: 2, inSource: source)
        #expect(updated == source)
    }

    @Test("applyToFile rewrites the file on disk")
    func applyToFile() throws {
        let dir = try makeTempDirectory(prefix: "marker-writer")
        defer { try? FileManager.default.removeItem(at: dir) } // silent: best-effort temp cleanup
        let file = dir.appendingPathComponent("Fixture.swift")
        try "let flag = [1].count == 0\n".write(to: file, atomically: true, encoding: .utf8)

        try MarkerWriter.applyToFile(
            marker: "// idiom:exempt", reason: nil, line: 1, path: file.path)

        let contents = try String(contentsOfFile: file.path, encoding: .utf8)
        #expect(contents == "let flag = [1].count == 0 // idiom:exempt\n")
    }
}

// MARK: - FindingsInbox extraction

@Suite("FindingsInbox item extraction")
struct FindingsInboxExtractionTests {

    @Test("advisory notes with locations become inbox items; errors and warnings are excluded")
    func severityFilter() {
        let diagnostics = [
            Diagnostic(severity: .note, message: "advisory", filePath: "/tmp/A.swift",
                       lineNumber: 3, ruleId: "idiom.empty-count"),
            Diagnostic(severity: .warning, message: "warn", filePath: "/tmp/A.swift",
                       lineNumber: 4, ruleId: "idiom.empty-count"),
            Diagnostic(severity: .error, message: "err", filePath: "/tmp/A.swift",
                       lineNumber: 5, ruleId: "safety.force-unwrap"),
        ]
        let items = FindingsInbox.items(from: makeMetadata(results: [makeResult(diagnostics: diagnostics)]))
        #expect(items.count == 1)
        #expect(items.first?.message == "advisory")
        #expect(items.first?.lineNumber == 3)
    }

    @Test("notes without a file path or line number are excluded")
    func locationRequired() {
        let diagnostics = [
            Diagnostic(severity: .note, message: "no path", lineNumber: 1, ruleId: "idiom.empty-count"),
            Diagnostic(severity: .note, message: "no line", filePath: "/tmp/A.swift",
                       ruleId: "idiom.empty-count"),
        ]
        let items = FindingsInbox.items(from: makeMetadata(results: [makeResult(diagnostics: diagnostics)]))
        #expect(items.isEmpty)
    }

    @Test("baseline-origin notes belong to the re-verify queue and are excluded")
    func baselineExcluded() {
        let diagnostics = [
            Diagnostic(severity: .note, message: "debt", filePath: "/tmp/A.swift",
                       lineNumber: 1, ruleId: "smell.parameter-count", origin: "baseline"),
            Diagnostic(severity: .note, message: "fresh", filePath: "/tmp/A.swift",
                       lineNumber: 2, ruleId: "smell.parameter-count"),
        ]
        let items = FindingsInbox.items(from: makeMetadata(results: [makeResult(diagnostics: diagnostics)]))
        #expect(items.count == 1)
        #expect(items.first?.message == "fresh")
    }

    @Test("duplicate diagnostics collapse to one item")
    func deduplicates() {
        let diagnostic = Diagnostic(
            severity: .note, message: "advisory", filePath: "/tmp/A.swift",
            lineNumber: 3, ruleId: "idiom.empty-count")
        let items = FindingsInbox.items(from: makeMetadata(results: [
            makeResult(checkerId: "one", diagnostics: [diagnostic, diagnostic]),
            makeResult(checkerId: "two", diagnostics: [diagnostic]),
        ]))
        #expect(items.count == 1)
    }

    @Test("items sort by file path, then line number")
    func sortOrder() {
        let diagnostics = [
            Diagnostic(severity: .note, message: "b9", filePath: "/tmp/B.swift",
                       lineNumber: 9, ruleId: "smell.nesting-depth"),
            Diagnostic(severity: .note, message: "a7", filePath: "/tmp/A.swift",
                       lineNumber: 7, ruleId: "idiom.empty-count"),
            Diagnostic(severity: .note, message: "a2", filePath: "/tmp/A.swift",
                       lineNumber: 2, ruleId: "idiom.empty-count"),
        ]
        let items = FindingsInbox.items(from: makeMetadata(results: [makeResult(diagnostics: diagnostics)]))
        #expect(items.map(\.message) == ["a2", "a7", "b9"])
    }

    @Test("items carry the resolved marker; unregistered rules carry nil")
    func markerResolution() throws {
        let diagnostics = [
            Diagnostic(severity: .note, message: "idiom", filePath: "/tmp/A.swift",
                       lineNumber: 1, ruleId: "idiom.empty-count"),
            Diagnostic(severity: .note, message: "unregistered", filePath: "/tmp/A.swift",
                       lineNumber: 2, ruleId: "complexity.cyclomatic"),
        ]
        let items = FindingsInbox.items(from: makeMetadata(results: [makeResult(diagnostics: diagnostics)]))
        #expect(items.count == 2)
        let idiomItem = try #require(items.first { $0.message == "idiom" })
        #expect(idiomItem.marker?.marker == "// idiom:exempt")
        let unregistered = try #require(items.first { $0.message == "unregistered" })
        #expect(unregistered.marker == nil)
    }
}

// MARK: - FindingsInbox acknowledge

@Suite("FindingsInbox acknowledge")
struct FindingsInboxAcknowledgeTests {

    @Test("acknowledging an item with no acknowledgment path throws a typed error")
    func notAcknowledgeable() {
        let item = InboxItem(
            ruleId: "complexity.cyclomatic", message: "advisory",
            filePath: "/tmp/A.swift", lineNumber: 1, origin: nil, marker: nil)
        #expect(throws: FindingsInboxError.notAcknowledgeable(ruleId: "complexity.cyclomatic")) {
            try FindingsInbox.acknowledge(item: item, reason: "any")
        }
    }

    @Test("a reason-required marker rejects a missing or blank reason", arguments: [nil, "", "   "])
    func reasonRequired(reason: String?) throws {
        let rule = try #require(AcknowledgeableRule.for(ruleId: "legibility.over-public-symbol", origin: nil))
        let item = InboxItem(
            ruleId: "legibility.over-public-symbol", message: "over-public",
            filePath: "/tmp/A.swift", lineNumber: 1, origin: nil, marker: rule)
        #expect(throws: FindingsInboxError.reasonRequired(ruleId: "legibility.over-public-symbol")) {
            try FindingsInbox.acknowledge(item: item, reason: reason)
        }
    }

    @Test("acknowledging writes the marker at the flagged location")
    func writesMarker() throws {
        let dir = try makeTempDirectory(prefix: "inbox-ack")
        defer { try? FileManager.default.removeItem(at: dir) } // silent: best-effort temp cleanup
        let file = dir.appendingPathComponent("Fixture.swift")
        try "let a = 1\nlet flag = [1].count == 0\n".write(to: file, atomically: true, encoding: .utf8)

        let rule = try #require(AcknowledgeableRule.for(ruleId: "idiom.empty-count", origin: nil))
        let item = InboxItem(
            ruleId: "idiom.empty-count", message: "prefer isEmpty",
            filePath: file.path, lineNumber: 2, origin: nil, marker: rule)
        try FindingsInbox.acknowledge(item: item, reason: "reviewed")

        let contents = try String(contentsOfFile: file.path, encoding: .utf8)
        #expect(contents == "let a = 1\nlet flag = [1].count == 0 // idiom:exempt reviewed\n")
    }
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
