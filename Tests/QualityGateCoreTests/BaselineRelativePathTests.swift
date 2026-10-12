import Foundation
import Testing
@testable import QualityGateCore

/// A committed ledger must not say where its author keeps their checkouts.
///
/// `adopt` recorded each debt's `filePath` exactly as the checker reported it — absolute. The
/// ledger is meant to be committed ("recorded debt is shared, not machine-local"), so a public
/// repository published `/Users/<name>/…` on every record. The path was never part of the
/// match key — the key is (rule, hash of the flagged line's text) — so a ledger can say
/// `Sources/…` instead and match exactly as it did, from any checkout.
@Suite("BaselineLedger: repo-relative paths")
struct BaselineRelativePathTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A project with two source files, at a fresh absolute location.
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-rel-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/Kit", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "let a = x!\nlet b = y!\n".write(
            to: sources.appendingPathComponent("Alpha.swift"), atomically: true, encoding: .utf8)
        try "let c = Int(z)\n".write(
            to: sources.appendingPathComponent("Beta.swift"), atomically: true, encoding: .utf8)
        return root
    }

    private func findings(in root: URL) -> [Diagnostic] {
        let alpha = root.appendingPathComponent("Sources/Kit/Alpha.swift").path
        let beta = root.appendingPathComponent("Sources/Kit/Beta.swift").path
        return [
            Diagnostic(severity: .error, message: "planted", filePath: alpha, lineNumber: 1, ruleId: "safety.force-unwrap"),
            Diagnostic(severity: .error, message: "planted", filePath: alpha, lineNumber: 2, ruleId: "safety.force-unwrap"),
            Diagnostic(severity: .warning, message: "planted", filePath: beta, lineNumber: 1, ruleId: "fallback.int-conversion-unguarded"),
        ]
    }

    private func result(_ diagnostics: [Diagnostic]) -> CheckResult {
        CheckResult(checkerId: "safety", status: .failed, diagnostics: diagnostics, duration: .zero)
    }

    /// The same project at a second absolute location.
    private func cloneProject(_ root: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }

    // MARK: - Writing

    @Test("adopt records each path relative to the project root")
    func adoptWritesRelativePaths() throws {
        let root = try makeProject()
        let ledger = BaselineLedger.adopt(
            findings: findings(in: root), recordedAt: now, decayDays: 180, projectRoot: root)
        #expect(ledger.records.map(\.filePath) == [
            "Sources/Kit/Alpha.swift", "Sources/Kit/Alpha.swift", "Sources/Kit/Beta.swift",
        ])
    }

    @Test("the saved ledger does not contain the checkout's location")
    func savedLedgerDoesNotNameTheCheckout() throws {
        let root = try makeProject()
        let ledger = BaselineLedger.adopt(
            findings: findings(in: root), recordedAt: now, decayDays: 180, projectRoot: root)
        let path = root.appendingPathComponent(".quality-gate-baseline.json").path
        try ledger.save(to: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let unescaped = text.replacingOccurrences(of: "\\/", with: "/")
        #expect(unescaped.contains(root.path) == false)
        #expect(unescaped.contains(root.resolvingSymlinksInPath().path) == false)
        #expect(unescaped.components(separatedBy: "\"filePath\" : \"Sources/Kit/").count == 4)
    }

    @Test("a path the checker already reported relative is kept as it is")
    func relativeInputIsKept() throws {
        let root = try makeProject()
        #expect(BaselineLedger.repoRelativePath("Sources/Kit/Alpha.swift", projectRoot: root) == "Sources/Kit/Alpha.swift")
    }

    @Test("a path outside the project root is not something to relativise")
    func outsidePathIsNotRelativised() throws {
        let root = try makeProject()
        #expect(BaselineLedger.repoRelativePath("/usr/include/stdio.h", projectRoot: root) == nil)
        // A sibling whose name merely begins with the root's is outside it too.
        #expect(BaselineLedger.repoRelativePath(root.path + "-other/Sources/A.swift", projectRoot: root) == nil)
    }

    // MARK: - Reading both forms

    @Test("a relative ledger absorbs the same findings from any checkout root")
    func relativeLedgerMatchesFromAnyCheckout() throws {
        let root = try makeProject()
        let ledger = BaselineLedger.adopt(
            findings: findings(in: root), recordedAt: now, decayDays: 180, projectRoot: root)
        let clone = try cloneProject(root)

        for checkout in [root, clone] {
            let applied = BaselineLedger.apply(ledger: ledger, to: [result(findings(in: checkout))], now: now)
            #expect(applied.summary.baselined == 3)
            #expect(applied.summary.newFindings == 0)
            #expect(applied.summary.expired == 0)
        }
    }

    @Test("an absolute-path ledger keeps matching, at its own location and at another")
    func absoluteLedgerStillMatches() throws {
        let root = try makeProject()
        // No root handed over: the paths are recorded as reported, which is what every ledger
        // written before this change holds.
        let legacy = BaselineLedger.adopt(findings: findings(in: root), recordedAt: now, decayDays: 180)
        #expect(legacy.records.compactMap(\.filePath).allSatisfy { $0.hasPrefix("/") })
        let clone = try cloneProject(root)

        for checkout in [root, clone] {
            let applied = BaselineLedger.apply(ledger: legacy, to: [result(findings(in: checkout))], now: now)
            #expect(applied.summary.baselined == 3)
            #expect(applied.summary.newFindings == 0)
        }
    }

    // MARK: - Rewriting an existing ledger

    @Test("relativising rewrites every path and leaves every other field byte-identical")
    func relativisingKeepsHashes() throws {
        let root = try makeProject()
        let legacy = BaselineLedger.adopt(findings: findings(in: root), recordedAt: now, decayDays: 180)
        let rewrite = legacy.relativized(projectRoot: root)

        #expect(rewrite.rewritten == 3)
        #expect(rewrite.unresolved == [])
        #expect(rewrite.ledger.records.map(\.filePath) == [
            "Sources/Kit/Alpha.swift", "Sources/Kit/Alpha.swift", "Sources/Kit/Beta.swift",
        ])
        #expect(rewrite.ledger.records.map(\.contentHash) == legacy.records.map(\.contentHash))
        #expect(rewrite.ledger.records.map(\.ruleId) == legacy.records.map(\.ruleId))
        #expect(rewrite.ledger.records.map(\.recordedAt) == legacy.records.map(\.recordedAt))
        #expect(rewrite.ledger.records.map(\.expiresAt) == legacy.records.map(\.expiresAt))
    }

    @Test("the rewritten ledger absorbs exactly the findings the original did")
    func relativisedLedgerAbsorbsTheSame() throws {
        let root = try makeProject()
        let legacy = BaselineLedger.adopt(
            findings: Array(findings(in: root).prefix(2)), recordedAt: now, decayDays: 180)
        let rewritten = legacy.relativized(projectRoot: root).ledger
        let run = [result(findings(in: root))]

        let before = BaselineLedger.apply(ledger: legacy, to: run, now: now)
        let after = BaselineLedger.apply(ledger: rewritten, to: run, now: now)
        #expect(before.summary.baselined == 2)
        #expect(before.summary.newFindings == 1)
        #expect(after.summary == before.summary)
        #expect(after.results.flatMap(\.diagnostics).map(\.severity)
            == before.results.flatMap(\.diagnostics).map(\.severity))
    }

    @Test("a ledger recorded at another checkout location is relativised by what exists here")
    func relativisingALedgerFromElsewhere() throws {
        let origin = try makeProject()
        let legacy = BaselineLedger.adopt(findings: findings(in: origin), recordedAt: now, decayDays: 180)
        // The file the ledger names is gone from the second checkout; its record is still
        // relativised, against the root the surviving files gave away.
        let here = try cloneProject(origin)
        try FileManager.default.removeItem(at: here.appendingPathComponent("Sources/Kit/Beta.swift"))

        let rewrite = legacy.relativized(projectRoot: here)
        #expect(rewrite.rewritten == 3)
        #expect(rewrite.unresolved == [])
        #expect(rewrite.ledger.records.map(\.filePath) == [
            "Sources/Kit/Alpha.swift", "Sources/Kit/Alpha.swift", "Sources/Kit/Beta.swift",
        ])
        #expect(rewrite.ledger.records.map(\.contentHash) == legacy.records.map(\.contentHash))
    }

    @Test("a path nothing here accounts for is left as it is and named")
    func unresolvablePathIsReported() throws {
        let root = try makeProject()
        let stray = BaselineRecord(
            ruleId: "safety.force-unwrap", contentHash: "abc", filePath: "/opt/elsewhere/Gone.swift",
            recordedAt: now, expiresAt: now.addingTimeInterval(86_400))
        let rewrite = BaselineLedger(records: [stray]).relativized(projectRoot: root)
        #expect(rewrite.rewritten == 0)
        #expect(rewrite.unresolved == ["/opt/elsewhere/Gone.swift"])
        #expect(rewrite.ledger.records == [stray])
    }

    @Test("relativising an already-relative ledger changes nothing")
    func relativisingIsIdempotent() throws {
        let root = try makeProject()
        let ledger = BaselineLedger.adopt(
            findings: findings(in: root), recordedAt: now, decayDays: 180, projectRoot: root)
        let rewrite = ledger.relativized(projectRoot: root)
        #expect(rewrite.rewritten == 0)
        #expect(rewrite.unresolved == [])
        #expect(rewrite.ledger == ledger)
    }

    @Test("a saved rewrite differs from the original file only on its filePath lines")
    func savedRewriteTouchesOnlyPaths() throws {
        let root = try makeProject()
        let legacy = BaselineLedger.adopt(findings: findings(in: root), recordedAt: now, decayDays: 180)
        let before = root.appendingPathComponent("before.json").path
        let after = root.appendingPathComponent("after.json").path
        try legacy.save(to: before)
        try BaselineLedger.load(from: before).relativized(projectRoot: root).ledger.save(to: after)

        let beforeLines = try String(contentsOfFile: before, encoding: .utf8)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let afterLines = try String(contentsOfFile: after, encoding: .utf8)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        #expect(beforeLines.count == afterLines.count)
        let changed = zip(beforeLines, afterLines).filter { $0 != $1 }
        #expect(changed.count == 3)
        #expect(changed.allSatisfy { $0.0.contains("\"filePath\"") && $0.1.contains("\"filePath\"") })
    }
}
