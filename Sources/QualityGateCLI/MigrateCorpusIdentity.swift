import ArgumentParser
import Foundation
#if canImport(os)
import os
#endif
import IJSSensor
import QualityGateCore

/// Propose (and optionally apply) manifest aliases mapping this project's
/// legacy corpus directories to its stable identity (Phase 0.4).
struct MigrateCorpusIdentity: AsyncParsableCommand {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "MigrateCorpusIdentity")

    static let configuration = CommandConfiguration(
        commandName: "migrate-corpus-identity",
        abstract: "Propose manifest aliases mapping legacy corpus directories to this project's stable identity.",
        discussion: """
        Runs the identity resolution chain (explicit config → normalized git \
        remote → basename) for the current checkout, then compares the result \
        against existing corpus directories. Without --apply this is a dry \
        run: the proposed alias map is printed for review. With --apply the \
        aliases are merged into manifest.yml — history is never moved.
        """
    )

    @Option(name: .long, help: "Path to the IJS corpus directory (default: consistency.corpusPath)")
    var corpusPath: String?

    @Flag(name: .long, help: "Write the proposed aliases into manifest.yml (default is a dry run)")
    var apply: Bool = false

    func run() async throws {
        let config: Configuration
        do {
            config = try Configuration.load(from: ".quality-gate.yml")
        } catch {
            Self.logger.warning("identity.config-load-failed: \(error.localizedDescription, privacy: .public) — using defaults")
            print("[migrate-corpus-identity] Warning: could not load .quality-gate.yml (\(error.localizedDescription)); using defaults.")
            config = Configuration()
        }

        guard let effectiveCorpusPath = corpusPath ?? config.consistency.corpusPath else {
            print("[migrate-corpus-identity] Error: No corpus path configured. Set consistency.corpusPath in .quality-gate.yml or use --corpus-path.")
            throw ExitCode(1)
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let identity = ProjectIdentity.resolve(cwd: cwd, explicitID: config.consistency.projectID)
        print("[migrate-corpus-identity] Resolved identity: \(identity.id) (source: \(identity.source.rawValue))")
        if let remote = identity.remote {
            print("[migrate-corpus-identity] Remote: \(remote)")
        }
        guard identity.source != .basename else {
            print("[migrate-corpus-identity] Identity is the directory basename (no usable git remote) — nothing to migrate.")
            return
        }

        // Legacy directories this checkout may have written under.
        var legacyCandidates = [cwd.lastPathComponent]
        if let configured = config.consistency.projectID {
            legacyCandidates.append(configured)
        }

        let telemetryDir = "\(effectiveCorpusPath)/telemetry" // SAFETY: configured corpus path
        let fm = FileManager.default
        let corpusDirectories: [String]
        if fm.fileExists(atPath: telemetryDir) { // SAFETY: read-only check on configured path
            do {
                corpusDirectories = try fm.contentsOfDirectory(atPath: telemetryDir) // SAFETY: reads configured corpus
            } catch {
                print("[migrate-corpus-identity] Error: Cannot read telemetry directory: \(error.localizedDescription)")
                throw ExitCode(1)
            }
        } else {
            corpusDirectories = []
        }

        let manifestURL = URL(fileURLWithPath: effectiveCorpusPath).appendingPathComponent("manifest.yml")
        var manifest = try CorpusManifest.load(from: manifestURL)

        let proposal = IdentityMigration.proposedAliases(
            identityID: identity.id,
            legacyCandidates: legacyCandidates,
            corpusDirectories: corpusDirectories,
            existingAliases: manifest.aliases)

        guard !proposal.isEmpty else {
            print("[migrate-corpus-identity] No new aliases needed — legacy directories are absent or already aliased.")
            return
        }

        print("[migrate-corpus-identity] Proposed aliases:")
        print("aliases:")
        for legacyDir in proposal.keys.sorted() {
            guard let target = proposal[legacyDir] else { continue }
            print("  \"\(legacyDir)\": \"\(target)\"")
        }

        guard apply else {
            print("[migrate-corpus-identity] Dry run — re-run with --apply to write manifest.yml.")
            return
        }

        manifest.aliases.merge(proposal) { current, _ in current }
        try manifest.save(to: manifestURL)
        Self.logger.notice("identity.aliases-applied: \(proposal.count, privacy: .public) alias(es) written to \(manifestURL.path, privacy: .public)")
        print("[migrate-corpus-identity] Applied \(proposal.count) alias(es) to \(manifestURL.path). History was not moved.")
    }
}
