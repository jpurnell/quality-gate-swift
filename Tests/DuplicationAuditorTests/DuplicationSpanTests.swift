import Foundation
import Testing
import QualityGateCore
@testable import DuplicationAuditor

/// A clone finding reports the region the clone occupies.
///
/// This is the one contributing rule whose span was never in doubt: the auditor already
/// computes `anchorSpan` to render `path:start-end` in its message, so the end line was being
/// formatted into a string and then discarded. A consumer counting duplicated lines had to
/// parse the message to recover what the checker already knew.
///
/// The span reported is the **anchor block's**, not the union of every site in the clone class.
/// A clone class spanning four files is four separate regions; one diagnostic cannot carry
/// them, and summing them would double-count code that appears once per site.
@Suite("DuplicationAuditor spans")
struct DuplicationSpanTests {

    /// A fixture package with two files sharing one long, high-variety block.
    private func fixtureRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dup-span-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources/Fixture")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        let block = (1...40).map { index in
            "    let value\(index) = compute(alpha: \(index), beta: \"tag\(index)\", gamma: \(index * 7))"
        }.joined(separator: "\n")

        let first = "func alpha() {\n\(block)\n}\n"
        let second = "func beta() {\n\(block)\n}\n"
        try first.write(to: sources.appendingPathComponent("First.swift"), atomically: true, encoding: .utf8)
        try second.write(to: sources.appendingPathComponent("Second.swift"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("A clone diagnostic reports the anchor block's region")
    func cloneReportsItsRegion() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let auditor = DuplicationAuditor(config: DuplicationConfig(), root: root.path)
        let result = try await auditor.check(configuration: Configuration())
        let clones = result.diagnostics.filter { $0.ruleId == "duplication.clone" }

        guard let diagnostic = clones.first else {
            Issue.record("expected a duplication.clone finding across the two fixture files")
            return
        }
        guard let span = diagnostic.lineSpan else {
            Issue.record("clone finding reported no span")
            return
        }
        // The shared block occupies lines 2-41 of each file; the clone must cover many lines,
        // not one.
        guard let lineCount = diagnostic.lineCount else {
            Issue.record("clone finding reported a span but no line count")
            return
        }
        #expect(span.lowerBound >= 1)
        #expect(span.upperBound > span.lowerBound)
        // The shared block is 40 lines of each file. Token-level maximal-block merging need not
        // land on exactly that boundary, so the assertion is a floor well above the noise —
        // specific enough to fail if the span collapsed to a point or to a handful of lines.
        #expect(lineCount >= 30)
    }

    @Test("The reported span agrees with the region named in the message")
    func spanAgreesWithTheMessage() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let auditor = DuplicationAuditor(config: DuplicationConfig(), root: root.path)
        let result = try await auditor.check(configuration: Configuration())

        guard let diagnostic = result.diagnostics.first(where: { $0.ruleId == "duplication.clone" }),
              let span = diagnostic.lineSpan else {
            Issue.record("expected a duplication.clone finding with a span")
            return
        }
        // The message renders every site as `path:start-end`; the anchor is the first.
        #expect(diagnostic.message.contains("\(span.lowerBound)-\(span.upperBound)"))
    }
}
