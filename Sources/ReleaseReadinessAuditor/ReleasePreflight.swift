import Foundation
import QualityGateCore

/// The release-scoped observer: the obligations that come due when a version is cut, checked at
/// the moment they come due.
///
/// ## Why these cannot be commit-time rules
///
/// `HermeticityContract` strips gate authority from anything not derivable from the working
/// tree, and it is right to: a document that has aged past a threshold is not evidence against
/// the commit in front of it, and blocking on the calendar teaches people to reach for
/// `--no-verify`. So staleness reports as a note and never blocks.
///
/// That leaves a hole nothing fills. The housekeeping obligations are **release-scoped** — the
/// master plan reconciled, the CHANGELOG's link definitions current, the README's claims still
/// true — and the only enforcement anywhere is commit-scoped. An obligation with no observer at
/// the moment it comes due is a process that does not run, which is exactly what was found: a
/// documented pass that had executed at most once, and a plan 44% wrong for two months.
///
/// A release is different in kind. It **is** the calendar event, so temporal findings are
/// legitimate here in a way they are not at commit time — nothing is being blamed on a commit,
/// because the thing under judgment is the release itself.
///
/// ## What this deliberately does not do
///
/// It does not re-run the gate. The gate already runs on every commit and every push, and a
/// preflight that duplicated it would be slow enough to skip — and a check that gets skipped is
/// worse than one that does not exist, because its presence implies coverage. This answers only
/// the questions no commit-time checker can legitimately answer.
public enum ReleasePreflight {

    /// One release-readiness question and its answer.
    public struct Finding: Sendable, Equatable {
        /// The rule that produced it.
        public let ruleId: String
        /// What is wrong, in one sentence.
        public let message: String
        /// What to do about it.
        public let remedy: String
    }

    /// Do the places that state this project's version agree?
    ///
    /// Three documents state a version independently, and nothing compares them, so each drifts
    /// alone. Measured on 2026-08-12: the CLI said `2.0.1`, the CHANGELOG's newest release said
    /// `2.0.2`, the newest tag said `v2.0.2`, and the maintainer said "about 2.6". Four answers
    /// to a question with one right answer.
    ///
    /// - Parameters:
    ///   - declaredVersion: The version the CLI reports for `--version`.
    ///   - changelogVersion: The newest released version in the CHANGELOG, or `nil`.
    ///   - candidateTag: The tag about to be cut, when there is one.
    /// - Returns: One finding per disagreement.
    public static func versionParity(
        declaredVersion: String,
        changelogVersion: String?,
        candidateTag: String?
    ) -> [Finding] {
        guard let changelogVersion else {
            return [Finding(
                ruleId: "release.no-documented-version",
                message: "The CHANGELOG documents no released version, so there is nothing to release.",
                remedy: "Add a dated `## [X.Y.Z]` heading for the version being cut.")]
        }

        var findings: [Finding] = []
        let documented = normalise(changelogVersion)

        if normalise(declaredVersion) != documented {
            findings.append(Finding(
                ruleId: "release.version-mismatch",
                message: "The CLI reports version \(declaredVersion) but the CHANGELOG's newest release is \(changelogVersion) — consumers are told two different things about the same build.",
                remedy: "Set the declared version to \(changelogVersion)."))
        }

        if let candidateTag, normalise(candidateTag) != documented {
            findings.append(Finding(
                ruleId: "release.tag-mismatch",
                message: "The candidate tag \(candidateTag) does not name the version the CHANGELOG documents (\(changelogVersion)).",
                remedy: "Tag the version being released, or correct the heading."))
        }
        return findings
    }

    /// Is anything still sitting under `## [Unreleased]`?
    ///
    /// Content under that heading is, by definition, what is being released. Cutting a version
    /// while it remains there ships the work and documents it as unshipped — the drift that put
    /// 57 commits under one `[Unreleased]` heading while the newest release heading stayed at
    /// 2.0.2 for six weeks.
    ///
    /// - Parameter changelog: The CHANGELOG's full text.
    /// - Returns: One finding when the section has content.
    public static func unreleasedIsEmpty(changelog: String) -> [Finding] {
        var inside = false
        var entries = 0

        for line in changelog.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if inside { break }
                inside = trimmed.lowercased().contains("unreleased")
                continue
            }
            if inside, !trimmed.isEmpty { entries += 1 }
        }

        guard entries > 0 else { return [] }
        return [Finding(
            ruleId: "release.unreleased-not-empty",
            message: "\(entries) line(s) remain under `## [Unreleased]` — that content is what this release ships, and leaving it there documents shipped work as unshipped.",
            remedy: "Move the `[Unreleased]` content under the new dated version heading.")]
    }

    /// Has the plan been reconciled since the last release?
    ///
    /// The temporal question, and the one that belongs here rather than at commit time. A plan
    /// whose `Last Updated` predates the release being cut has not been reconciled against what
    /// is shipping, which is the housekeeping step the process documents and does not perform.
    ///
    /// - Parameters:
    ///   - planLastUpdated: The plan's `Last Updated` date.
    ///   - releaseDate: The date on the version heading being released.
    /// - Returns: One finding when the plan predates the release.
    public static func planReconciled(planLastUpdated: Date?, releaseDate: Date?) -> [Finding] {
        guard let planLastUpdated, let releaseDate else { return [] }
        guard planLastUpdated < releaseDate else { return [] }
        return [Finding(
            ruleId: "release.plan-not-reconciled",
            message: "The master plan was last updated before the release it is shipping alongside — its architecture tables and status were not reconciled against what is going out.",
            remedy: "Reconcile the plan against the shipped code and bump `Last Updated`.")]
    }

    /// The date on the newest dated release heading, e.g. `## [3.0.0] — 2026-08-12`.
    ///
    /// `[Unreleased]` is skipped: it is the section being emptied, not a release.
    ///
    /// - Parameter changelog: The CHANGELOG's full text.
    /// - Returns: The date, or `nil` when no dated release heading exists.
    public static func newestReleaseDate(in changelog: String) -> Date? {
        for line in changelog.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("## "), !trimmed.lowercased().contains("unreleased") else {
                continue
            }
            if let date = isoDate(in: trimmed) { return date }
        }
        return nil
    }

    /// The plan's `**Last Updated:** YYYY-MM-DD`.
    ///
    /// - Parameter plan: The master plan's full text.
    /// - Returns: The date, or `nil` when the line is absent or undated.
    public static func lastUpdated(inPlan plan: String) -> Date? {
        for line in plan.lines where line.lowercased().contains("last updated") {
            if let date = isoDate(in: line) { return date }
        }
        return nil
    }

    /// The first `YYYY-MM-DD` in a line, read as a calendar date.
    ///
    /// Deliberately ISO-only. A release heading written in prose dates cannot be compared
    /// reliably, and guessing at one would put a fabricated fact into a rule that blocks a
    /// release — so an unparseable date is reported as absent, which the callers treat as no
    /// evidence rather than as a finding.
    static func isoDate(in text: String) -> Date? {
        guard let match = text.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: String(text[match]))
    }

    /// Strips a `v` or `Project@v` prefix so two spellings of one version compare equal.
    static func normalise(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = value.lastIndex(of: "@") { value = String(value[value.index(after: at)...]) }
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        return value
    }
}
