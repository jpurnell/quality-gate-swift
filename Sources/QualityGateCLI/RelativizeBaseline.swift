import ArgumentParser
import DiskCleaner
import Foundation
import QualityGateCore

/// `quality-gate relativize-baseline` — rewrites an existing ledger's paths repo-relative.
///
/// `adopt` used to record each debt's `filePath` as the checker reported it, which is
/// absolute. The ledger is meant to be committed, so a public repository published
/// `/Users/<name>/…` on every record. `adopt` writes repo-relative paths now; this brings a
/// ledger written before that into the same form, in place.
///
/// It changes paths and nothing else. A record matches a finding by (rule, content hash), and
/// the hash is of the rule and the flagged line's text — never of the path — so the rewritten
/// ledger covers exactly the findings it covered before, with every hash, recorded date,
/// expiry and attribution as it was. Run it from the repository root, where the ledger lives.
struct RelativizeBaseline: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "relativize-baseline",
        abstract: "Rewrite the baseline ledger's file paths repo-relative — paths only; no hash, date or match changes."
    )

    // Spelled `--preview`, for the reason `clean` spells it so: the root command declares
    // `--dry-run`, ArgumentParser binds a parent's options ahead of a subcommand's, and a flag
    // of that name here is never set. The first build of this command had one, and a "dry
    // run" rewrote the ledger. `--dry-run` is honoured all the same, read off the raw
    // arguments, because typing it and getting a write is the accident to rule out.
    @Flag(name: .customLong("preview"), help: "Report what would be rewritten without saving the ledger. `--dry-run` works too.")
    var preview: Bool = false

    func run() throws {
        let dryRun = DiskCleaner.wantsPreview(previewFlag: preview, arguments: CommandLine.arguments)
        let path = ".quality-gate-baseline.json"
        guard FileManager.default.fileExists(atPath: path) else {
            print("No baseline ledger at \(path) — nothing to rewrite.")
            return
        }
        let ledger = try BaselineLedger.load(from: path)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let outcome = ledger.relativized(projectRoot: root)

        let absoluteBefore = ledger.records.filter { $0.filePath?.hasPrefix("/") == true }.count
        print("Ledger: \(path) — \(ledger.records.count) record(s), \(absoluteBefore) with an absolute path.")

        if outcome.rewritten > 0, !dryRun {
            try outcome.ledger.save(to: path)
        }
        let verb = dryRun ? "Would rewrite" : "Rewrote"
        print("\(verb) \(outcome.rewritten) path(s) repo-relative. Hashes, dates and matches are unchanged.")

        guard outcome.unresolved.isEmpty else {
            print("\(outcome.unresolved.count) path(s) left absolute — outside this repository, and nothing here says where they were recorded:")
            for unresolved in outcome.unresolved {
                print("  \(unresolved)")
            }
            throw ExitCode(1)
        }
        if outcome.rewritten > 0, !dryRun {
            print("Commit \(path) to publish the rewritten ledger.")
        }
    }
}
