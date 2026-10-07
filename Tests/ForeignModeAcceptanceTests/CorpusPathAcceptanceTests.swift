import Foundation
import QualityGateCore
import QualityGateTestKit
import Testing

/// A bad `corpusPath`, asserted on the shipped binary and on the tree it leaves behind.
///
/// The unit tests prove the rule. These prove the consequence that was only ever visible
/// on disk: a gate run that created a directory named `${ORG_JUDGEMENT_CORPUS:-}` inside the
/// repository it was checking, filled it with telemetry, and exited 0.
@Suite("Corpus path — acceptance")
struct CorpusPathAcceptanceTests {

    private enum AcceptanceError: Error {
        case binaryNotFound
        case processFailed(String)
    }

    private struct Fixture {
        let base: URL
        let root: URL
        let home: URL
    }

    /// The inherited environment minus every `GIT_*` variable: inside a hook they point at
    /// the outer repository.
    private func scrubbedEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let result = try ProcessRunner.run(
            "/usr/bin/git",
            arguments: arguments,
            currentDirectory: directory.path,
            environment: scrubbedEnvironment(),
            mergeStderr: true,
            timeout: 120)
        guard result.exitCode == 0 else {
            throw AcceptanceError.processFailed("git \(arguments.joined(separator: " "))")
        }
    }

    /// A committed one-target package with the given gate config and `.gitignore`.
    private func makeFixture(config: String, gitignore: String = ".build/\n") throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-path-acceptance-\(UUID().uuidString)", isDirectory: true)
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
        /// Counts down to zero.
        public func countDown(_ depth: Int) -> Int {
            guard depth > 0 else { return 0 }
            return countDown(depth - 1)
        }
        """.write(to: sources.appendingPathComponent("Demo.swift"), atomically: true, encoding: .utf8)
        try config.write(
            to: root.appendingPathComponent(".quality-gate.yml"), atomically: true, encoding: .utf8)
        try gitignore.write(
            to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        try runGit(["init", "-q"], in: root)
        try runGit(["add", "-A"], in: root)
        try runGit(["-c", "user.name=acceptance", "-c", "user.email=acceptance@test",
                    "commit", "-qm", "init"], in: root)
        return Fixture(base: base, root: root, home: home)
    }

    private func runGate(_ arguments: [String], in fixture: Fixture) throws
        -> (exitCode: Int32, output: String)
    {
        guard let binary = BuiltProducts.gateBinary else { throw AcceptanceError.binaryNotFound }
        var environment = scrubbedEnvironment()
        environment["QUALITY_GATE_HOME"] = fixture.home.path
        environment.removeValue(forKey: "QG_FOREIGN_REPO_ROOT")
        environment.removeValue(forKey: "QG_SKIP")
        // Unset on purpose: the original failure needed nothing in the environment, and a
        // developer who happens to export this must not change what is being tested.
        environment.removeValue(forKey: "ORG_JUDGEMENT_CORPUS")
        let result = try ProcessRunner.run(
            binary.path,
            arguments: arguments,
            currentDirectory: fixture.root.path,
            environment: environment,
            mergeStderr: true,
            timeout: 300)
        return (result.exitCode, result.stdout)
    }

    private func porcelain(in fixture: Fixture) throws -> String {
        let result = try ProcessRunner.run(
            "/usr/bin/git",
            arguments: ["status", "--porcelain", "--untracked-files=all"],
            currentDirectory: fixture.root.path,
            environment: scrubbedEnvironment(),
            timeout: 60)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func exists(_ relativePath: String, in fixture: Fixture) -> Bool {
        FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(relativePath).path)
    }

    // MARK: - The original failure

    @Test("${VAR:-} as corpusPath is refused before anything runs, and creates nothing")
    func shellReferenceIsRefusedAndCreatesNothing() throws {
        let fixture = try makeFixture(config: """
            consistency:
              corpusPath: ${ORG_JUDGEMENT_CORPUS:-}   # set in the environment; no absolute path in the repo
              projectID: Demo

            """)
        defer { try? FileManager.default.removeItem(at: fixture.base) } // silent: temp fixture cleanup

        let run = try runGate(["--no-cache", "--check", "recursion"], in: fixture)

        #expect(run.exitCode == 1)
        #expect(run.output.contains("`consistency.corpusPath` is set to `${ORG_JUDGEMENT_CORPUS:-}`"))
        #expect(run.output.contains("Nothing was run."))
        #expect(!run.output.contains("[recursion]"))
        #expect(!run.output.contains("PASSED"))
        #expect(!exists("${ORG_JUDGEMENT_CORPUS:-}", in: fixture))
        #expect(try porcelain(in: fixture) == "")
    }

    @Test("exporting the variable does not make the literal acceptable")
    func exportingTheVariableChangesNothing() throws {
        // The gate never read the variable; a run with it exported still wrote to the
        // literal directory. Refusing must not depend on the environment either.
        let fixture = try makeFixture(config: """
            consistency:
              corpusPath: ${ORG_JUDGEMENT_CORPUS:-}
              projectID: Demo

            """)
        defer { try? FileManager.default.removeItem(at: fixture.base) } // silent: temp fixture cleanup
        let corpus = fixture.base.appendingPathComponent("real-corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)

        guard let binary = BuiltProducts.gateBinary else { throw AcceptanceError.binaryNotFound }
        var environment = scrubbedEnvironment()
        environment["QUALITY_GATE_HOME"] = fixture.home.path
        environment["ORG_JUDGEMENT_CORPUS"] = corpus.path
        environment.removeValue(forKey: "QG_FOREIGN_REPO_ROOT")
        environment.removeValue(forKey: "QG_SKIP")
        let run = try ProcessRunner.run(
            binary.path,
            arguments: ["--no-cache", "--check", "recursion"],
            currentDirectory: fixture.root.path,
            environment: environment,
            mergeStderr: true,
            timeout: 300)

        #expect(run.exitCode == 1)
        #expect(!exists("${ORG_JUDGEMENT_CORPUS:-}", in: fixture))
        #expect(try FileManager.default.contentsOfDirectory(atPath: corpus.path) == [])
    }

    // MARK: - Containment

    @Test("a relative corpus inside the repository, unignored, is refused and creates nothing")
    func unignoredInRepositoryCorpusIsRefused() throws {
        let fixture = try makeFixture(config: """
            consistency:
              corpusPath: corpus
              projectID: Demo

            """)
        defer { try? FileManager.default.removeItem(at: fixture.base) } // silent: temp fixture cleanup

        let run = try runGate(["--no-cache", "--check", "recursion"], in: fixture)

        #expect(run.exitCode == 1)
        #expect(run.output.contains("`consistency.corpusPath` is set to `corpus`"))
        #expect(run.output.contains("inside the repository being checked"))
        #expect(!run.output.contains("[recursion]"))
        #expect(!exists("corpus", in: fixture))
        #expect(try porcelain(in: fixture) == "")
    }

    @Test("a relative corpus inside the repository that git ignores still works")
    func ignoredInRepositoryCorpusIsWritten() throws {
        let fixture = try makeFixture(
            config: """
                consistency:
                  corpusPath: .ijs-corpus
                  projectID: Demo

                """,
            gitignore: ".build/\n.ijs-corpus/\n")
        defer { try? FileManager.default.removeItem(at: fixture.base) } // silent: temp fixture cleanup

        let run = try runGate(["--no-cache", "--check", "recursion"], in: fixture)

        #expect(run.exitCode == 0)
        #expect(run.output.contains("[recursion]"))
        #expect(exists(".ijs-corpus/telemetry/Demo", in: fixture))
        #expect(try porcelain(in: fixture) == "")
    }

    @Test("a corpus outside the repository is written to, and the tree stays clean")
    func outsideCorpusIsWritten() throws {
        let fixture = try makeFixture(config: """
            consistency:
              corpusPath: ../corpus
              projectID: Demo

            """)
        defer { try? FileManager.default.removeItem(at: fixture.base) } // silent: temp fixture cleanup

        let run = try runGate(["--no-cache", "--check", "recursion"], in: fixture)

        #expect(run.exitCode == 0)
        #expect(FileManager.default.fileExists(
            atPath: fixture.base.appendingPathComponent("corpus/telemetry/Demo").path))
        #expect(try porcelain(in: fixture) == "")
    }

    // MARK: - Visibility

    @Test("consistency against a corpus that does not resolve is SKIPPED, never PASSED")
    func unresolvableCorpusIsVisiblySkipped() throws {
        let missing = "/nonexistent-\(UUID().uuidString)/corpus"
        let fixture = try makeFixture(config: """
            consistency:
              corpusPath: \(missing)
              projectID: Demo

            """)
        defer { try? FileManager.default.removeItem(at: fixture.base) } // silent: temp fixture cleanup

        let run = try runGate(["--strict", "--no-cache", "--check", "consistency"], in: fixture)

        #expect(run.output.contains(
            "Not checked: corpus path '\(missing)' does not resolve to a directory."))
        #expect(run.output.contains("SKIPPED"))
        #expect(!run.output.contains("[consistency] Institutional Consistency: ✓"))
        // Visible, but not red: a note on a skipped result does not fail `--strict`.
        #expect(run.exitCode == 0)
    }
}
