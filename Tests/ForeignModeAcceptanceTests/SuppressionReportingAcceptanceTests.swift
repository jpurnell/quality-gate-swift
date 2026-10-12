import Foundation
import QualityGateCore
import QualityGateTestKit
import Testing

/// What a run was told not to raise, asserted on the shipped binary's output.
///
/// The unit tests prove the records and the totals. These prove the thing a person or a
/// dashboard actually consumes: that the totals are in `--format json` and on the terminal,
/// that they are the same on a cache replay, that the ratchet moves the exit code, and that a
/// configuration file the gate cannot read stops the run instead of quietly becoming defaults.
@Suite("Suppression reporting — acceptance")
struct SuppressionReportingAcceptanceTests {

    private enum AcceptanceError: Error {
        case binaryNotFound
        case notJSON(String)
    }

    private struct Fixture {
        let root: URL
        let home: URL
    }

    /// A package with one `try?` under a token-reason marker, one unbounded recursion that
    /// configuration switches off, and one generated file that configuration excludes.
    private func makeFixture(config: String) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("suppression-acceptance-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Quiet", isDirectory: true)
        let home = base.appendingPathComponent("qg-home", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/Quiet", isDirectory: true)
        let generated = sources.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Quiet",
            targets: [.target(name: "Quiet")]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation

        /// Reads a file, or nothing.
        public func load(_ path: String) -> String? {
            try? String(contentsOfFile: path, encoding: .utf8) // silent: best effort
        }

        /// Walks forever: a self-call with no guard-driven base case.
        public func walk(_ depth: Int) -> Int {
            walk(depth + 1)
        }
        """.write(to: sources.appendingPathComponent("Quiet.swift"), atomically: true, encoding: .utf8)
        try """
        /// Generated; excluded from the walk by configuration.
        public func generated(_ depth: Int) -> Int {
            generated(depth + 1)
        }
        """.write(to: generated.appendingPathComponent("Gen.swift"), atomically: true, encoding: .utf8)
        try config.write(to: root.appendingPathComponent(".quality-gate.yml"), atomically: true, encoding: .utf8)
        return Fixture(root: root, home: home)
    }

    private static let config = """
        excludePatterns:
          - "Generated/"
        overrides:
          recursion.unconditional-self-call: off
        logging:
          projectType: cli

        """

    private func runGate(_ arguments: [String], in fixture: Fixture) throws -> (exitCode: Int32, output: String) {
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
            mergeStderr: false,
            timeout: 300)
        return (result.exitCode, result.stdout + result.stderr)
    }

    /// The JSON document in a run's standard output, which may be preceded by notices.
    private func suppressions(in output: String) throws -> [String: Any] {
        guard let start = output.range(of: "{\n") else { throw AcceptanceError.notJSON(output) }
        let object = try JSONSerialization.jsonObject(with: Data(output[start.lowerBound...].utf8))
        guard let report = object as? [String: Any],
              let summary = report["summary"] as? [String: Any],
              let found = summary["suppressions"] as? [String: Any] else {
            throw AcceptanceError.notJSON(output)
        }
        return found
    }

    private func jsonRun(_ fixture: Fixture, cache: Bool) throws -> [String: Any] {
        var arguments = ["--check", "recursion,logging", "--no-index-build", "--format", "json"]
        if !cache { arguments.append("--no-cache") }
        guard let binary = BuiltProducts.gateBinary else { throw AcceptanceError.binaryNotFound }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["QUALITY_GATE_HOME"] = fixture.home.path
        environment.removeValue(forKey: "QG_FOREIGN_REPO_ROOT")
        environment.removeValue(forKey: "QG_SKIP")
        let result = try ProcessRunner.run(
            binary.path, arguments: arguments, currentDirectory: fixture.root.path,
            environment: environment, mergeStderr: false, timeout: 300)
        return try suppressions(in: result.stdout)
    }

    // MARK: - Totals

    @Test("--format json carries the marker, the config override and the exclusion, with totals")
    func jsonCarriesEveryForm() throws {
        let fixture = try makeFixture(config: Self.config)
        let found = try jsonRun(fixture, cache: false)

        #expect(found["suppressed"] as? Int == 2)
        #expect(found["acknowledged"] as? Int == 0)
        #expect(found["baselined"] as? Int == 0)
        #expect(found["policy"] as? String == "note")
        #expect(found["suppressedByForm"] as? [String: Int] == ["// silent:": 1, "config overrides: off": 1])

        let byChecker = try #require(found["byChecker"] as? [String: [String: Any]])
        #expect(byChecker["logging"]?["suppressed"] as? Int == 1)
        #expect(byChecker["recursion"]?["suppressed"] as? Int == 1)

        let exclusions = try #require(found["exclusions"] as? [[String: Any]])
        #expect(exclusions.compactMap { $0["form"] as? String } == ["excludePatterns", "logging.projectType"])
        #expect(exclusions.first?["matchedFiles"] as? Int == 1)
    }

    @Test("A cache replay reports the same totals as the run that filled the cache")
    func replayReportsTheSameTotals() throws {
        let fixture = try makeFixture(config: Self.config)
        let first = try jsonRun(fixture, cache: true)
        let replay = try jsonRun(fixture, cache: true)

        #expect(first["suppressed"] as? Int == 2)
        #expect(replay["suppressed"] as? Int == 2)
        #expect(replay["suppressedByForm"] as? [String: Int] == first["suppressedByForm"] as? [String: Int])
        #expect(replay["acknowledged"] as? Int == first["acknowledged"] as? Int)
    }

    @Test("The terminal summary prints the totals and does not change the verdict")
    func terminalPrintsTotalsAndStillPasses() throws {
        let fixture = try makeFixture(config: Self.config)
        let run = try runGate(["--strict", "--no-cache", "--no-index-build", "--check", "recursion,logging"], in: fixture)

        #expect(run.output.contains(
            "   Silenced findings: 0 acknowledged (reason validated) · 2 suppressed (not validated)\n"
                + "     suppressed by form: // silent: 1 · config overrides: off 1\n"
                + "     by checker: recursion 1 suppressed · logging 1 suppressed\n"))
        #expect(run.output.contains(
            "   Exclusions in force (what they hid is not measured):\n"
                + "     excludePatterns — 1 pattern(s) matched 1 .swift file(s); they were not audited\n"
                + "     logging.projectType — logging.print-statement and logging.no-os-logger-import are not checked\n"))
        #expect(run.output.contains("Quality Gate: PASSED"))
        #expect(run.exitCode == 0)
    }

    // MARK: - The ratchet

    @Test("`suppressions: warn` turns each suppression into a warning that --strict gates on")
    func ratchetGatesUnderStrict() throws {
        let fixture = try makeFixture(config: Self.config + "suppressions: warn\n")
        let arguments = ["--no-cache", "--no-index-build", "--continue-on-failure", "--check", "recursion,logging"]

        let strict = try runGate(["--strict"] + arguments, in: fixture)
        #expect(strict.output.contains(
            "`// silent:` silences logging.silent-try without a validated reason (2 words, 8 required): \"best effort\""))
        #expect(strict.output.contains(
            "configuration silences recursion.unconditional-self-call without a validated reason: "
                + "overrides: recursion.unconditional-self-call: off"))
        #expect(strict.output.contains("0 error(s), 2 warning(s)"))
        #expect(strict.exitCode == 1)

        let lenient = try runGate(arguments, in: fixture)
        #expect(lenient.exitCode == 0)
    }

    @Test("`suppressions: error` fails the run without --strict")
    func ratchetErrorFails() throws {
        let fixture = try makeFixture(config: Self.config + "suppressions: error\n")
        let run = try runGate(
            ["--no-cache", "--no-index-build", "--continue-on-failure", "--check", "recursion,logging"], in: fixture)
        #expect(run.output.contains("2 error(s), 0 warning(s)"))
        #expect(run.exitCode == 1)
    }

    @Test("A marker whose reason validates does not trip the ratchet")
    func validatedReasonPassesTheRatchet() throws {
        let fixture = try makeFixture(config: "suppressions: error\n")
        try """
        import Foundation

        /// Reads a file, or nothing.
        public func load(_ path: String) -> String? {
            // silent: a missing settings file is the ordinary first-run case and the caller supplies defaults
            try? String(contentsOfFile: path, encoding: .utf8)
        }
        """.write(
            to: fixture.root.appendingPathComponent("Sources/Quiet/Quiet.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Sources/Quiet/Generated"))
        let run = try runGate(["--strict", "--no-cache", "--no-index-build", "--check", "logging"], in: fixture)

        #expect(run.output.contains("Silenced findings: 1 acknowledged (reason validated) · 0 suppressed (not validated)"))
        #expect(run.output.contains("Quality Gate: PASSED"))
        #expect(run.exitCode == 0)
    }

    // MARK: - Configuration that cannot be read

    @Test("A configuration that does not decode stops the run and names the file and the error")
    func undecodableConfigurationStopsTheRun() throws {
        let fixture = try makeFixture(config: "excludePatterns: 5\n")
        let run = try runGate(["--no-cache", "--check", "recursion"], in: fixture)

        #expect(run.exitCode == 1)
        #expect(run.output.contains("❌ configuration: .quality-gate.yml could not be read: "))
        #expect(run.output.contains("`excludePatterns`"))
        #expect(run.output.contains("   Nothing was run. Correct .quality-gate.yml and run again.\n"))
        #expect(!run.output.contains("Quality Gate Results"))
    }

    @Test("A configuration that is not YAML stops the run")
    func malformedYAMLStopsTheRun() throws {
        let fixture = try makeFixture(config: "excludePatterns: [unclosed\n")
        let run = try runGate(["--no-cache", "--check", "recursion"], in: fixture)

        #expect(run.exitCode == 1)
        #expect(run.output.contains("❌ configuration: .quality-gate.yml could not be read: "))
        #expect(run.output.contains("Nothing was run."))
        #expect(!run.output.contains("Quality Gate Results"))
    }

    @Test("An unknown `suppressions:` value stops the run rather than defaulting to note")
    func unknownPolicyStopsTheRun() throws {
        let fixture = try makeFixture(config: "suppressions: loud\n")
        let run = try runGate(["--no-cache", "--check", "recursion"], in: fixture)

        #expect(run.exitCode == 1)
        #expect(run.output.contains("suppressions: 'loud' is not one of note, warn, error"))
        #expect(run.output.contains("Nothing was run."))
    }

    @Test("An unknown top-level key is a loud warning naming the key, and the run continues")
    func unknownKeyWarnsAndRuns() throws {
        let fixture = try makeFixture(config: "exclude:\n  - Generated/\n")
        let run = try runGate(["--no-cache", "--no-index-build", "--check", "recursion"], in: fixture)

        #expect(run.output.contains("⚠️  configuration: `.quality-gate.yml` sets 1 key this version does not recognise."))
        #expect(run.output.contains("  · `exclude` — did you mean `excludePatterns`?"))
        #expect(run.output.contains("Quality Gate Results"))
        // The unrecognised key excluded nothing, so both recursions are found.
        #expect(run.output.contains("0 error(s), 2 warning(s)"))
        #expect(run.exitCode == 0)
    }
}
