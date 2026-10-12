import Foundation
import QualityGateCore
import QualityGateTestKit
import Testing

/// The baseline ledger's paths, asserted on the shipped binary and the file it leaves.
///
/// The unit tests prove the rewrite. These prove what only a run shows: that `adopt` writes
/// a ledger with no checkout location in it, that `relativize-baseline` changes the file a
/// repository already has and nothing about what it covers — and that asking it for a preview
/// does not write. That last one is here because the first build of the command failed it:
/// the root command owns `--dry-run`, a subcommand's flag of the same name is never set, and
/// a "dry run" rewrote three ledgers.
@Suite("Baseline ledger paths — acceptance")
struct BaselinePathAcceptanceTests {

    private enum AcceptanceError: Error {
        case binaryNotFound
    }

    private struct Fixture {
        let base: URL
        let root: URL
        let home: URL
        var ledger: URL { root.appendingPathComponent(".quality-gate-baseline.json") }
    }

    /// A one-target package holding the line SwiftCLIKit's ledger records most often:
    /// `Sources/SwiftCLIKit/Util/Formatting.swift:34`, `let total = Int(seconds)`.
    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-path-acceptance-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Demo", isDirectory: true)
        let home = base.appendingPathComponent("qg-home", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Demo",
            targets: [.target(name: "Demo")]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        /// Whole seconds in a duration.
        public func wholeSeconds(_ seconds: Double) -> Int {
            let total = Int(seconds)
            return total
        }
        """.write(to: sources.appendingPathComponent("Formatting.swift"), atomically: true, encoding: .utf8)
        try "enabledCheckers:\n  - fallback\n".write(
            to: root.appendingPathComponent(".quality-gate.yml"), atomically: true, encoding: .utf8)
        return Fixture(base: base, root: root, home: home)
    }

    private func runGate(_ arguments: [String], in fixture: Fixture) throws -> (exitCode: Int32, output: String) {
        guard let binary = BuiltProducts.gateBinary else { throw AcceptanceError.binaryNotFound }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["QUALITY_GATE_HOME"] = fixture.home.path
        environment.removeValue(forKey: "QG_FOREIGN_REPO_ROOT")
        environment.removeValue(forKey: "QG_SKIP")
        let result = try ProcessRunner.run(
            binary.path,
            arguments: arguments,
            currentDirectory: fixture.root.path,
            environment: environment,
            mergeStderr: true,
            timeout: 300)
        return (result.exitCode, result.stdout)
    }

    private func records(_ fixture: Fixture) throws -> [BaselineRecord] {
        try BaselineLedger.load(from: fixture.ledger.path).records
    }

    /// Rewrites the adopted ledger the way a ledger written before this change looks: every
    /// path absolute, under a checkout root that is not this one.
    private func makeLegacy(_ fixture: Fixture) throws {
        let legacy = try records(fixture).map { record in
            BaselineRecord(
                ruleId: record.ruleId,
                contentHash: record.contentHash,
                filePath: "/Users/someone/Development/Swift/Tools/Demo/" + (record.filePath ?? ""),
                recordedAt: record.recordedAt,
                expiresAt: record.expiresAt)
        }
        try BaselineLedger(records: legacy).save(to: fixture.ledger.path)
    }

    private func baselineLine(_ output: String) -> String {
        output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .first { $0.contains("Baseline:") }
            .map(String.init) ?? ""
    }

    @Test("adopt writes a ledger that does not say where the checkout is")
    func adoptWritesRelativePaths() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) } // silent: temp fixture cleanup

        let run = try runGate(["adopt", "--checkers", "fallback"], in: fixture)
        #expect(run.exitCode == 0)
        #expect(try records(fixture).map(\.filePath) == ["Sources/Demo/Formatting.swift"])
        #expect(try records(fixture).map(\.ruleId) == ["fallback.int-conversion-unguarded"])

        let text = try String(contentsOf: fixture.ledger, encoding: .utf8)
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(text.contains(fixture.base.lastPathComponent) == false)
    }

    @Test("relativize-baseline rewrites the paths and the gate covers the same debt")
    func relativizeRewritesAndCoversTheSame() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) } // silent: temp fixture cleanup
        _ = try runGate(["adopt", "--checkers", "fallback"], in: fixture)
        try makeLegacy(fixture)
        let before = try records(fixture)
        #expect(before.map(\.filePath) == ["/Users/someone/Development/Swift/Tools/Demo/Sources/Demo/Formatting.swift"])
        let coveredBefore = baselineLine(try runGate(["--no-cache", "--check", "fallback"], in: fixture).output)

        let run = try runGate(["relativize-baseline"], in: fixture)
        #expect(run.exitCode == 0)
        #expect(run.output.contains("Rewrote 1 path(s) repo-relative."))

        let after = try records(fixture)
        #expect(after.map(\.filePath) == ["Sources/Demo/Formatting.swift"])
        #expect(after.map(\.contentHash) == before.map(\.contentHash))
        #expect(after.map(\.recordedAt) == before.map(\.recordedAt))
        #expect(after.map(\.expiresAt) == before.map(\.expiresAt))

        let coveredAfter = baselineLine(try runGate(["--no-cache", "--check", "fallback"], in: fixture).output)
        #expect(coveredBefore.contains("Baseline: 1 debt(s) covered, 0 EXPIRED (re-verify), 0 new finding(s) gating."))
        #expect(coveredAfter == coveredBefore)
    }

    @Test("a preview does not write, whichever way it is asked for", arguments: ["--preview", "--dry-run"])
    func previewDoesNotWrite(flag: String) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) } // silent: temp fixture cleanup
        _ = try runGate(["adopt", "--checkers", "fallback"], in: fixture)
        try makeLegacy(fixture)
        let before = try Data(contentsOf: fixture.ledger)

        let run = try runGate(["relativize-baseline", flag], in: fixture)
        #expect(run.exitCode == 0)
        #expect(run.output.contains("Would rewrite 1 path(s) repo-relative."))
        #expect(try Data(contentsOf: fixture.ledger) == before)
    }
}
