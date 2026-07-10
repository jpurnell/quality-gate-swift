import ArgumentParser
import Foundation
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

        // Re-enter the standard run path — parity by construction.
        var arguments = plan.gateArguments
        if !checkers.isEmpty {
            arguments.append("--check")
            arguments.append(contentsOf: checkers)
        }
        var gate = try QualityGateCLI.parse(arguments)
        try await gate.run()
    }
}
