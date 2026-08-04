import ArgumentParser
import Foundation
#if canImport(os)
import os
#endif
import GateCI
import QualityGateCore

/// `quality-gate ci` — the canonical CI invocation (Phase 2).
///
/// One entrypoint, three callers: this subcommand computes a ``CIRunPlan``
/// and re-enters the standard run path with the plan's arguments, so local
/// hook, local manual run, and CI run cannot drift by construction. The
/// plan forces determinism: no index build unless explicitly opted in, no
/// result cache, UTC, strict by default, SARIF + JSON summary artifacts
/// always produced.
struct CICommand: AsyncParsableCommand {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "CICommand")

    static let configuration = CommandConfiguration(
        commandName: "ci",
        abstract: "Run the gate with CI-appropriate deterministic defaults (same core path as every other run)."
    )

    @Option(name: .long, help: "Index policy: 'none' (default — never build) or 'build' (workflow explicitly opted in)")
    var index: String = "none"

    @Option(name: .customLong("output-dir"), help: "Directory for the SARIF and JSON summary artifacts")
    var outputDir: String = ".quality-gate-ci"

    @Flag(name: .customLong("no-strict"), help: "Do not fail on warnings (the org default is strict)")
    var noStrict: Bool = false

    // Named --checkers, not --check: the root command also declares --check,
    // and ArgumentParser lets parent options match after the subcommand name,
    // so a same-named child option would be silently shadowed (captured into
    // the discarded root instance) — observed, not theoretical.
    @Option(name: .customLong("checkers"), parsing: .upToNextOption, help: "Specific checkers to run (passthrough to --check; defaults to the standard set)")
    var checkers: [String] = []

    @Option(name: .customLong("corpus-remote"), help: "Git remote of the telemetry corpus: cloned before the run, telemetry pushed after (interim transport, Phase 2 §4)")
    var corpusRemote: String?

    func run() async throws {
        guard let indexMode = CIRunPlan.IndexMode(rawValue: index) else {
            print("ERROR: --index must be 'none' or 'build'")
            throw ExitCode(1)
        }
        let plan = CIRunPlan(
            indexMode: indexMode,
            outputDirectory: outputDir,
            strict: !noStrict)

        // Force the declared environment before anything runs.
        for (key, value) in plan.environmentOverrides {
            setenv(key, value, 1)
        }

        // Interim CI telemetry transport (Phase 2 §4): clone the corpus
        // before the run so telemetry writes land in the clone.
        var transport: CorpusGitTransport?
        var corpusRoot: URL?
        if let corpusRemote {
            let cloneDir = URL(fileURLWithPath: outputDir, isDirectory: true)
                .appendingPathComponent("corpus", isDirectory: true)
            let gitTransport = CorpusGitTransport(remote: corpusRemote, workdir: cloneDir)
            corpusRoot = try gitTransport.prepare()
            transport = gitTransport
            print("[ijs] Corpus cloned from \(corpusRemote)")
        }

        // Re-enter the standard run path — parity by construction.
        var arguments = plan.gateArguments
        if let corpusRoot {
            arguments.append(contentsOf: ["--telemetry-corpus-path", corpusRoot.path])
        }
        if !checkers.isEmpty {
            arguments.append("--check")
            arguments.append(contentsOf: checkers)
        }
        let gate = try QualityGateCLI.parse(arguments)
        var gateError: Error?
        do {
            try await gate.run()
        } catch {
            // Held, logged, and rethrown after the publish step below — the
            // corpus must receive a red run's telemetry too.
            Self.logger.warning("Gate run failed; publishing telemetry before rethrowing: \(error.localizedDescription, privacy: .public)")
            gateError = error
        }

        // Publish after the run, pass or fail — a red run's telemetry is
        // exactly the data the corpus exists to hold. Publish failure is
        // logged, never masks the gate verdict (fail-open).
        if let transport {
            do {
                let identity = CIIdentityProbe.detect(
                    environment: ProcessInfo.processInfo.environment)
                let message = identity.map {
                    "telemetry: \($0.repository)@\(String($0.commit.prefix(8))) via \($0.provider) run \($0.workflowRunID)"
                } ?? "telemetry: quality-gate ci run"
                try transport.publish(message: message)
                print("[ijs] Telemetry pushed to corpus remote")
            } catch {
                Self.logger.warning("Corpus publish failed (telemetry retained locally): \(error.localizedDescription, privacy: .public)")
                print("⚠ Corpus publish failed — telemetry retained in \(outputDir)/corpus: \(error.localizedDescription)")
            }
        }
        if let gateError {
            throw gateError
        }
    }
}
