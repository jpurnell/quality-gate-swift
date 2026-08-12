import Foundation
import QualityGateCore

/// The release-tag invariant: a version this project publishes must be resolvable by whoever
/// reads about it.
///
/// ## Three questions, previously one
///
/// The original rule asked only whether a tag *name* matching the CHANGELOG's latest version
/// existed locally. That is unsound in both directions at once — it blocked a correct workflow
/// and passed two genuinely broken releases:
///
/// - **Parity** — is there a tag for the documented version at all? Real, but not answerable at
///   commit time, because the tag names a commit that does not exist yet.
/// - **Identity** — does that tag *contain* the entry it claims? `git tag v9.9.9 <any-commit>`
///   satisfied the name test while the tagged tree documented no such release.
/// - **Reachability** — is the tag actually going to the remote? A tag created and never pushed
///   satisfied the name test while consumers still could not resolve the release. That is the
///   exact failure this checker was written for, with a green gate on top of it.
///
/// ## Where each one is allowed to bite
///
/// Parity is advisory on a normal run and blocking at a push boundary. That is not a weakening:
/// commit time is the wrong place for it, because the project's own order is *gate green, then
/// commit*, and a rule satisfiable only by inverting that order teaches people to reach for
/// `--no-verify`. Push is where the failure becomes visible to consumers and also the first
/// moment the tag can exist.
///
/// Identity blocks only for a tag *this push publishes*, which is narrower than it first looks
/// like it should be. The narrowing was forced by the first repository it ran against:
/// `quality-gate-swift`'s own `v2.0.2` points at a commit whose CHANGELOG documents
/// `[Unreleased]`, `[2026.07.12]` and `[2026.07.10]` and never mentions 2.0.2 — the tag was cut
/// before the entry was written. The finding is true and worth reporting. But the only way to
/// satisfy it is to move a tag that is already on the remote, and a rule whose remedy is
/// rewriting published history is unsatisfiable in exactly the way the commit-time parity rule
/// was. So a historical mismatch is a note, and the release you are actually publishing has to
/// be right.
public enum ReleaseTagInvariant {

    /// Is the documented version tagged at all?
    ///
    /// - Parameters:
    ///   - version: The latest released version from the CHANGELOG.
    ///   - tags: Local tag names, with or without a `v` or `Project@v` prefix.
    ///   - isBoundary: Whether this run is a push boundary, which is what earns the error.
    /// - Returns: One finding, or none when the version is tagged.
    public static func parity(version: String, tags: [String], isBoundary: Bool) -> [Diagnostic] {
        guard !hasTag(for: version, in: tags) else { return [] }
        return [Diagnostic(
            severity: isBoundary ? .error : .note,
            message: isBoundary
                ? "CHANGELOG documents version \(version) but no matching git tag exists, and this push does not add one — consumers will not be able to resolve this release."
                : "CHANGELOG documents version \(version) with no matching git tag yet. Tag it before pushing; this is a note because the tag names a commit that does not exist until you make it.",
            ruleId: "release-untagged-version",
            suggestedFix: "git tag -a v\(version) -m \"Version \(version)\" && git push --atomic origin HEAD v\(version)"
        )]
    }

    /// Does the tag contain the CHANGELOG entry it claims?
    ///
    /// - Parameters:
    ///   - version: The version the tag is supposed to release.
    ///   - tag: The tag name, for the message.
    ///   - changelogAtTag: `CHANGELOG.md` as of that tag, or `nil` when it cannot be read.
    ///   - isPublishing: Whether this run pushes the tag. A tag going out now must be correct;
    ///     one that went out months ago can only be corrected by moving published history.
    /// - Returns: One finding when the tagged tree contradicts the tag, else none.
    public static func identity(
        version: String, tag: String, changelogAtTag: String?, isPublishing: Bool
    ) -> [Diagnostic] {
        // Absent is not false. A shallow clone, or a tag predating the file, means the fact
        // cannot be established — and a finding invented from missing evidence is worse than
        // no finding, because it is unfixable.
        guard let changelog = changelogAtTag else { return [] }
        guard !documents(version: version, in: changelog) else { return [] }
        return [Diagnostic(
            severity: isPublishing ? .error : .note,
            message: "Tag `\(tag)` does not contain a CHANGELOG entry for \(version) — the tag names a commit that never released this version, so resolving it gives consumers something else.",
            ruleId: "release-tag-content-mismatch",
            suggestedFix: "Move the tag to the commit that documents \(version), or correct the version the CHANGELOG claims."
        )]
    }

    /// Is the tag reaching the remote — in this push, or already there?
    ///
    /// - Parameters:
    ///   - version: The documented version.
    ///   - tags: Local tag names.
    ///   - pushedRefs: The refs git is about to push, or `nil` outside a boundary run.
    ///   - remoteHasTag: Consulted only when the tag is not in this push. The network is not
    ///     touched when the answer is already visible in the ref list.
    /// - Returns: One finding when the tag will not exist on the remote, else none.
    public static func boundary(
        version: String,
        tags: [String],
        pushedRefs: [PushedRef]?,
        remoteHasTag: (String) -> Bool
    ) -> [Diagnostic] {
        // "No tag anywhere" is `parity`'s finding. Two rules reporting one cause is noise.
        guard let tag = matchingTag(for: version, in: tags) else { return [] }
        guard let pushedRefs else { return [] }

        let pushedTags = pushedRefs.filter { !$0.isDeletion }.compactMap(\.tagName)
        if pushedTags.contains(where: {
            ReleaseReadinessAuditor.normalizeVersion($0)
                == ReleaseReadinessAuditor.normalizeVersion(version)
        }) {
            return []
        }
        guard !remoteHasTag(tag) else { return [] }

        return [Diagnostic(
            severity: .error,
            message: "Tag `\(tag)` exists locally but is not in this push and is not on the remote — the release will be documented and unresolvable, which is the failure this rule exists to prevent.",
            ruleId: "release-tag-unpushed",
            suggestedFix: "Push the tag with the commit: git push --atomic origin HEAD \(tag)"
        )]
    }

    /// Whether any tag names this version, under the same normalisation the name test uses.
    static func hasTag(for version: String, in tags: [String]) -> Bool {
        matchingTag(for: version, in: tags) != nil
    }

    /// The tag naming this version, spelled as the repository spells it.
    static func matchingTag(for version: String, in tags: [String]) -> String? {
        let wanted = ReleaseReadinessAuditor.normalizeVersion(version)
        return tags.first { ReleaseReadinessAuditor.normalizeVersion($0) == wanted }
    }

    /// Whether a CHANGELOG documents a version in any of its heading spellings.
    static func documents(version: String, in changelog: String) -> Bool {
        let wanted = ReleaseReadinessAuditor.normalizeVersion(version)
        for line in changelog.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            guard !heading.lowercased().contains("unreleased") else { continue }
            let candidate = heading
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: " ").first.map(String.init) ?? ""
            if ReleaseReadinessAuditor.normalizeVersion(
                candidate.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) == wanted {
                return true
            }
        }
        return false
    }
}
