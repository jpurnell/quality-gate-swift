import ArgumentParser
import Foundation
import QualityGateCore
import ReleaseReadinessAuditor

/// `quality-gate release` — the observer that runs when a release comes due.
///
/// §9.4 spells this `release --preflight`. The flag is not here: it had exactly one value, so it
/// was not a choice, and `unreachable` correctly reported it as a symbol nothing reads. A flag
/// carried for symmetry with a mode that does not exist yet is API that rots before it is used.
/// If a second mode ever arrives, it can bring its own flag.
///
/// `DocGenerated.md` §9.4 named this as the missing piece and predicted it would be the item
/// most likely to be forgotten, *"because it is the only one that is not a checker."* The
/// housekeeping obligations are release-scoped — reconcile the plan, complete the CHANGELOG,
/// check the README's claims — and every enforcement mechanism in this tool is commit-scoped.
/// An obligation with no observer at the moment it comes due is a process that does not run,
/// which is what the evidence showed: a documented pass that had executed at most once, and an
/// architecture table 44% wrong for two months.
///
/// ## Why it does not re-run the gate
///
/// The gate already runs on every commit and every push. A preflight that repeated it would be
/// slow enough to skip, and a check people skip is worse than one that does not exist, because
/// its presence implies coverage. This answers only what no commit-time checker legitimately
/// can — including the temporal question, which belongs here precisely because a release *is*
/// the calendar event and nothing is being blamed on a commit.
struct Release: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Check the obligations that come due when a version is cut."
    )

    @Option(name: .long, help: "The tag about to be cut, e.g. v3.0.0. Checked against the version the CHANGELOG documents.")
    var tag: String?

    @Option(name: .long, help: "Path to the configuration file.")
    var config: String = ".quality-gate.yml"

    func run() async throws {
        let root = FileManager.default.currentDirectoryPath
        let configuration = (try? Configuration.load(from: config)) ?? Configuration() // silent: an unreadable config falls back to defaults, which name the conventional paths this command reads

        let changelogPath = (root as NSString)
            .appendingPathComponent(configuration.releaseReadiness.changelogPath)
        let planPath = ((root as NSString)
            .appendingPathComponent(configuration.status.guidelinesPath) as NSString)
            .appendingPathComponent(configuration.status.masterPlanPath)

        // SAFETY: CLI tool reads its own project's CHANGELOG
        let changelog = (try? String(contentsOfFile: changelogPath, encoding: .utf8)) ?? ""
        // SAFETY: CLI tool reads its own project's master plan
        let plan = (try? String(contentsOfFile: planPath, encoding: .utf8)) ?? ""

        var findings = ReleasePreflight.versionParity(
            declaredVersion: QualityGateCLI.configuration.version,
            changelogVersion: ReleaseReadinessAuditor.parseLatestChangelogVersion(content: changelog),
            candidateTag: tag)
        findings += ReleasePreflight.unreleasedIsEmpty(changelog: changelog)
        findings += ReleasePreflight.planReconciled(
            planLastUpdated: ReleasePreflight.lastUpdated(inPlan: plan),
            releaseDate: ReleasePreflight.newestReleaseDate(in: changelog))

        guard !findings.isEmpty else {
            print("✅ Release preflight: the version story is consistent and the plan is current.")
            return
        }

        print("\n❌ Release preflight: \(findings.count) obligation(s) outstanding\n")
        for finding in findings {
            print("  ❌ \(finding.ruleId)")
            print("     \(finding.message)")
            print("     💡 \(finding.remedy)\n")
        }
        print("These come due at the release, not at the commit — that is why nothing has")
        print("mentioned them until now.")
        throw ExitCode(1)
    }
}
