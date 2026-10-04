import Foundation
import QualityGateCore
import QualityGateTestKit
import Testing

/// `--strict` and checker selection, asserted on the shipped binary's exit code.
///
/// The unit tests prove the tally and the selection rules. These prove the thing a hook
/// actually consumes: the process exit status. They exist because the failure they guard
/// against was only ever visible there — the summary printed `0 error(s), 4 warning(s)`
/// under `--strict` and the process exited 0, so a caller reading the exit code was told
/// the opposite of what a caller reading the screen was told.
@Suite("Strict exit code and checker selection — acceptance")
struct StrictExitCodeAcceptanceTests {

    private enum AcceptanceError: Error {
        case binaryNotFound
    }

    /// A one-target package whose only finding is a warning from a checker whose status
    /// is computed from errors alone.
    private func makeFixture(config: String = "") throws -> (root: URL, home: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("strict-acceptance-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Warny", isDirectory: true)
        let home = base.appendingPathComponent("qg-home", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/Warny", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Warny",
            targets: [.target(name: "Warny")]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        /// Walks forever: a self-call with no guard-driven base case.
        public func walk(_ depth: Int) -> Int {
            walk(depth + 1)
        }
        """.write(to: sources.appendingPathComponent("Warny.swift"), atomically: true, encoding: .utf8)
        // A repo config makes the run resident, so nothing depends on an overlay. An empty
        // mapping is still a config file.
        try (config.isEmpty ? "vendorPaths: []\n" : config)
            .write(to: root.appendingPathComponent(".quality-gate.yml"), atomically: true, encoding: .utf8)
        return (root, home)
    }

    private func runGate(_ arguments: [String], in fixture: (root: URL, home: URL)) throws
        -> (exitCode: Int32, output: String)
    {
        guard let binary = BuiltProducts.gateBinary else { throw AcceptanceError.binaryNotFound }
        // No `GIT_*`: inside a hook they point at the outer repository.
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

    @Test("--strict exits 1 on a warning from a checker whose status ignores it (R2)")
    func strictFailsOnACountedWarning() throws {
        let fixture = try makeFixture()

        let strict = try runGate(["--strict", "--no-cache", "--check", "recursion"], in: fixture)
        #expect(strict.output.contains("0 error(s), 1 warning(s)"))
        #expect(strict.output.contains("Quality Gate: FAILED (--strict: 1 warning)"))
        #expect(strict.exitCode == 1)

        let lenient = try runGate(["--no-cache", "--check", "recursion"], in: fixture)
        #expect(lenient.output.contains("0 error(s), 1 warning(s)"))
        #expect(lenient.exitCode == 0)
    }

    @Test("an unrelated override does not decide the exit code (R3)")
    func unrelatedOverrideDoesNotDecideTheExitCode() throws {
        let plain = try makeFixture()
        let overridden = try makeFixture(config: """
            overrides:
              some-rule-that-never-fires: warning

            """)
        let arguments = ["--strict", "--no-cache", "--check", "recursion"]
        #expect(try runGate(arguments, in: plain).exitCode == 1)
        #expect(try runGate(arguments, in: overridden).exitCode == 1)
    }

    @Test("--check a,b runs both checkers (C1)")
    func commaListRunsBothCheckers() throws {
        let fixture = try makeFixture()
        let run = try runGate(
            ["--no-cache", "--no-index-build", "--check", "fp-safety,fallback"], in: fixture)
        #expect(run.output.contains("[fp-safety]"))
        #expect(run.output.contains("[fallback]"))
        #expect(!run.output.contains("Nothing to do"))
    }

    @Test("--check with an unknown id exits 64 and names it (C3)")
    func unknownCheckerIsAUsageError() throws {
        let fixture = try makeFixture()
        let run = try runGate(["--check", "bogus"], in: fixture)
        #expect(run.exitCode == 64)
        #expect(run.output.contains("'bogus'"))
    }

    @Test("one unknown id among good ones fails the invocation — no partial run (C4)")
    func oneUnknownIdFailsTheWholeInvocation() throws {
        let fixture = try makeFixture()
        let run = try runGate(["--check", "recursion", "--check", "bogus"], in: fixture)
        #expect(run.exitCode == 64)
        #expect(run.output.contains("'bogus'"))
        #expect(!run.output.contains("[recursion]"))
    }

    @Test("a typo in enabledCheckers exits 1 and names it (C6)")
    func unknownConfiguredCheckerIsAConfigurationError() throws {
        let fixture = try makeFixture(config: """
            enabledCheckers:
              - recursoin

            """)
        let run = try runGate([], in: fixture)
        #expect(run.exitCode == 1)
        #expect(run.output.contains("'recursoin'"))
        #expect(run.output.contains("recursion"))
    }

    @Test("a selection that excludes everything it selected is never exit 0")
    func emptySelectionIsNeverExitZero() throws {
        let fixture = try makeFixture()
        let run = try runGate(["--check", "recursion", "--exclude", "recursion"], in: fixture)
        #expect(run.exitCode == 64)
        #expect(!run.output.contains("PASSED"))
    }

    @Test("a retired id is refused in --check with directions, and accepted in --exclude")
    func retiredIdKeepsItsOwnMessage() throws {
        let fixture = try makeFixture()
        let requested = try runGate(["--check", "disk-clean"], in: fixture)
        #expect(requested.exitCode == 1)
        #expect(requested.output.contains("`--check disk-clean` has moved: run `quality-gate clean` instead."))

        // `scripts/onboard-corpus.sh` passes `--exclude disk-clean`; it must keep working.
        let excluded = try runGate(
            ["--no-cache", "--check", "recursion", "--exclude", "disk-clean"], in: fixture)
        #expect(excluded.exitCode == 0)
        #expect(excluded.output.contains("[recursion]"))
        #expect(excluded.output.contains("'disk-clean' is no longer a checker"))
    }
}
