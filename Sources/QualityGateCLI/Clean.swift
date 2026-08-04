import ArgumentParser
import DiskCleaner
import Foundation

/// `quality-gate clean` — destructive maintenance, deliberately outside the gate.
///
/// Cleanup used to ride along as a `QualityChecker`, which put a tree-mutating tool
/// behind a protocol meant for read-only diagnosis; it once wiped the `.build/` index
/// store mid-run and fabricated a 61-error result for its peers. It is a verb, not a
/// check, and it lives here alongside `adopt` and `re-verify` for that reason.
struct Clean: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Remove build artifacts (.build, .docc-build) and optionally compact git history.")

    @Flag(name: .long, help: "Also run `git gc --aggressive --prune=now`.")
    var gc: Bool = false

    // Spelled `--preview`, not `--dry-run`: the root command already declares
    // `--dry-run`, and ArgumentParser binds parent options ahead of a subcommand's, so a
    // flag by that name here is silently shadowed and stays false. `--dry-run` is still
    // honored — see `DiskCleaner.wantsPreview(previewFlag:arguments:)` — because typing
    // it and getting a deletion is exactly the accident this command must not have.
    @Flag(name: .customLong("preview"), help: "Report what would be removed without deleting anything. `--dry-run` works too.")
    var preview: Bool = false

    func run() async throws {
        let dryRun = DiskCleaner.wantsPreview(
            previewFlag: preview, arguments: CommandLine.arguments)
        let summary = DiskCleaner().clean(dryRun: dryRun, runGitGC: gc)

        if dryRun {
            print("🔍 Preview — nothing was removed.")
        }
        for message in summary.messages {
            print("   \(message)")
        }
        for warning in summary.warnings {
            print("⚠️  \(warning)")
        }
    }
}
