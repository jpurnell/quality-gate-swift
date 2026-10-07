import ArgumentParser
import Foundation
import QualityGateLogging
import CorpusKit
import QualityGateCore

/// Rebuild the corpus's per-project run indexes from its run files.
///
/// Each project keeps `telemetry/<project>/index.jsonl` — one line per run, appended when the
/// run is written — so that reading a project's history is reading one file. The index is
/// derived: the run files are the truth and every line can be regenerated from the file it
/// names. This command regenerates them. It is the backfill for runs recorded before the
/// index existed, and the repair for an index that readers keep reporting as short.
struct ReindexCorpus: AsyncParsableCommand {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "ReindexCorpus")

    static let configuration = CommandConfiguration(
        commandName: "reindex-corpus",
        abstract: "Rebuild the corpus's per-project run indexes from its run files.",
        discussion: """
        Readers never need this to be correct: a run with no index line is read \
        from its own file. They need it to be fast. Each project's index is \
        rewritten atomically, so a reader sees the old one or the new one. \
        Run files are read, never changed.
        """
    )

    @Option(name: .long, help: "Path to the IJS corpus directory (default: consistency.corpusPath)")
    var corpusPath: String?

    @Option(name: .long, help: "Rebuild one project's index instead of every project's")
    var project: String?

    func run() async throws {
        let config: Configuration
        do {
            config = try Configuration.load(from: ".quality-gate.yml")
        } catch {
            Self.logger.warning("reindex.config-load-failed: \(error.localizedDescription, privacy: .public) — using defaults")
            print("[reindex-corpus] Warning: could not load .quality-gate.yml (\(error.localizedDescription)); using defaults.")
            config = Configuration()
        }

        guard let effectiveCorpusPath = corpusPath ?? config.consistency.corpusPath else {
            print("[reindex-corpus] Error: No corpus path configured. Set consistency.corpusPath in .quality-gate.yml or use --corpus-path.")
            throw ExitCode(1)
        }

        let writer = TelemetryWriter()
        let projects: [CorpusPath]
        if let project {
            guard CorpusPath.isSingleComponent(project) else {
                print("[reindex-corpus] Error: '\(project)' is not a project identifier.")
                throw ExitCode(1)
            }
            projects = [CorpusPath(basePath: effectiveCorpusPath, projectID: project)]
        } else {
            do {
                projects = try await writer.discoverProjects(in: effectiveCorpusPath)
                    .sorted { $0.projectID < $1.projectID }
            } catch {
                print("[reindex-corpus] Error: Cannot list the corpus: \(error.localizedDescription)")
                throw ExitCode(1)
            }
        }

        var total = 0
        var failed = 0
        for corpus in projects {
            do {
                let count = try await writer.rebuildIndex(for: corpus)
                total += count
                if count > 0 {
                    print("[reindex-corpus] \(corpus.projectID): \(count) run(s)")
                }
            } catch {
                failed += 1
                Self.logger.error("reindex.project-failed: \(corpus.projectID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                print("[reindex-corpus] Error: \(corpus.projectID): \(error.localizedDescription)")
            }
        }
        print("[reindex-corpus] Indexed \(total) run(s) across \(projects.count) project(s).")
        if failed > 0 {
            print("[reindex-corpus] \(failed) project(s) could not be indexed.")
            throw ExitCode(1)
        }
    }
}
