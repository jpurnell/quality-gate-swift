import ArgumentParser
import Foundation
import QualityGateCore

/// `quality-gate config` — show the effective configuration and its origins.
///
/// Phase 1's answer to "which config am I running?": every top-level section
/// is attributed to the layer that declared it (repo → overlay → user-global
/// → built-in), plus the exact files consulted.
struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show where each configuration section comes from (repo → overlay → user-global → built-in)."
    )

    @Flag(name: .long, help: "Print the per-section provenance table (default behavior; kept for discoverability).")
    var explain: Bool = false

    @Option(name: .shortAndLong, help: "Path to the repo configuration file")
    var config: String = ".quality-gate.yml"

    func run() async throws {
        let resolution = try LayeredConfig.resolve(repoConfigPath: config)
        print("Configuration provenance for \(resolution.identity)")
        print("═══════════════════════════════════════════════")
        if explain {
            print(resolution.provenance.renderTable())
        } else {
            print("Consulted files:")
            print("  repo:        \(resolution.provenance.repoConfigPath ?? "(none)")")
            print("  overlay:     \(resolution.provenance.overlayConfigPath ?? "(none)")")
            print("  user-global: \(resolution.provenance.userGlobalConfigPath ?? "(none)")")
            print("")
            print("Run `quality-gate config --explain` for the per-section origin table.")
        }
    }
}
