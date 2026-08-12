import Foundation
import QualityGateCore

/// Generates `CHANGELOG.md`'s link-reference definitions from the version headings above them.
///
/// `CLAUDE.md` names these "easy to leave stale when a version is added". Measured, they were
/// not stale — they were **absent**, and had been for four releases, so every `## [2.0.2]`
/// rendered on GitHub as literal text with brackets. A convention nobody ever completed once
/// is a different failure from one that drifted, and it is the cheaper one to fix: there is no
/// history to reconcile, only a derivation nobody wrote down.
///
/// ## The circularity is apparent, not real
///
/// The headings are the human-authored source of truth about what shipped; the definitions are
/// the derivation. A version with no heading is invisible to this rule, which is why
/// `release-readiness` keeps owning the tagged-but-unwritten gap.
///
/// ## Why the version list is not `git tag`
///
/// Tags looked like the better source — they are the authority on what actually shipped, and
/// this repository has five against four bracketed headings. Rejected because refs are not the
/// working tree: a shallow clone, a tags-excluded fetch, or a fresh CI checkout would move the
/// verdict without moving a byte of source, which forfeits `.hermetic` and with it the
/// authority to block a commit.
///
/// The cost of that decision is stated rather than hidden. A link definition has to name a ref
/// *exactly*, so `DocGeneratedConfig/tagPrefix` has to supply the one thing the tree cannot,
/// and a repository whose tags are inconsistently prefixed cannot be served by any single
/// value. This checker will not notice — it certifies that the definitions follow from the
/// headings, never that the URLs resolve.
public struct ChangelogLinksGenerator: RegionGenerator {

    /// The file the headings are read from, which is also the file the region lives in.
    public static let changelogPath = "CHANGELOG.md"

    /// The id that appears in the region's delimiters.
    public let id = "changelog-links"

    /// What a reader should check when this region disagrees with the document.
    public let derivedFrom =
        "the `## [version]` headings in CHANGELOG.md, plus `doc-generated.repositoryURL`"

    /// Creates the generator.
    public init() {}

    /// One definition per bracketed heading, newest first, chained as compare links.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root; only `CHANGELOG.md` is read.
    ///   - currentBody: Ignored. Every line here is derived from the headings, so a definition
    ///     that disagrees with them is drift rather than authorship.
    ///   - configuration: Supplies the repository URL and the tag prefix, neither of which is
    ///     derivable from the tree.
    /// - Returns: The definitions, newline-separated, with no trailing newline.
    /// - Throws: ``RegionGeneratorError/ungeneratable(reason:)`` when the repository URL is
    ///   absent, the changelog is unreadable, or it carries no version heading at all.
    public func generate(
        projectRoot: URL, currentBody: String, configuration: Configuration
    ) throws -> String {
        let configured = configuration.docGenerated.repositoryURL?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configured.isEmpty else {
            throw RegionGeneratorError.ungeneratable(
                reason: "No `doc-generated.repositoryURL` is configured, and a repository URL "
                    + "guessed from `git remote` would be a ref, not a fact about the tree. "
                    + "Set it in `.quality-gate.yml`.")
        }
        var base = configured
        while base.hasSuffix("/") { base.removeLast() }

        let url = projectRoot.appendingPathComponent(Self.changelogPath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw RegionGeneratorError.ungeneratable(
                reason: "`\(Self.changelogPath)` is absent or unreadable, so there are no "
                    + "version headings to derive definitions from.")
        }

        let headings = Self.versionHeadings(in: contents)
        guard !headings.isEmpty else {
            throw RegionGeneratorError.ungeneratable(
                reason: "`\(Self.changelogPath)` carries no `## <version>` heading. An empty "
                    + "region here would claim the derivation ran and found nothing, which is "
                    + "not the same as the file having no releases.")
        }

        let prefix = configuration.docGenerated.tagPrefix
        var definitions: [String] = []
        for (index, heading) in headings.enumerated() where heading.isBracketed {
            let predecessor = headings.count > index + 1 ? headings[index + 1] : nil
            definitions.append(
                Self.definition(for: heading, predecessor: predecessor, base: base, prefix: prefix))
        }
        return definitions.joined(separator: "\n")
    }

    /// The link-reference definition for one heading.
    ///
    /// Three shapes, and which one applies is decided by what sits *below* the heading rather
    /// than by the heading itself:
    ///
    /// - **Unreleased with a release behind it** — the range from that release to `HEAD`.
    /// - **Unreleased with nothing behind it** — there is no range, so the commit list.
    /// - **The oldest heading in the file** — nothing to compare against, so its tag.
    static func definition(
        for heading: VersionHeading, predecessor: VersionHeading?, base: String, prefix: String
    ) -> String {
        let label = "[\(heading.label)]: \(base)"
        guard let previous = predecessor.map({ prefix + $0.version }) else {
            return heading.isUnreleased
                ? "\(label)/commits/HEAD"
                : "\(label)/releases/tag/\(prefix + heading.version)"
        }
        let target = heading.isUnreleased ? "HEAD" : prefix + heading.version
        return "\(label)/compare/\(previous)...\(target)"
    }

    /// One `## …` heading that names a version, or the unreleased section.
    struct VersionHeading: Equatable {

        /// The text between the brackets, spelled as the document spells it.
        ///
        /// This is the definition's left-hand side, so it is never normalised: it has to match
        /// the `[2.0.2]` reference in the body character for character or it defines nothing.
        let label: String

        /// The bare version, with any leading `v` removed.
        ///
        /// The ref side, where the prefix comes from configuration instead — so a document
        /// spelling its heading `## [v1.2.0]` still produces one consistently-prefixed ref.
        /// Empty for the unreleased heading, which names no version.
        let version: String

        /// Whether the heading is written as a link, i.e. `## [1.0.0]` rather than `## 1.0.0`.
        ///
        /// Only a bracketed heading needs a definition. An unbracketed one still takes part in
        /// the chain — it is a real release and the release below it really did follow it —
        /// but nothing in the document references it, so defining it would add a line no
        /// reader can reach.
        let isBracketed: Bool

        /// Whether this is the unreleased section, which has a label but no version.
        let isUnreleased: Bool
    }

    /// The version headings, in document order — which is newest first by convention.
    ///
    /// Fence state is tracked for the same reason the region scanner tracks it: a changelog
    /// that documents this very convention will show a `## [1.0.0]` inside a code block, and a
    /// parser that read it would derive a definition for a release that does not exist.
    static func versionHeadings(in contents: String) -> [VersionHeading] {
        var headings: [VersionHeading] = []
        var insideFence = false

        for line in contents.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                continue
            }
            guard !insideFence, trimmed.hasPrefix("## ") else { continue }
            let text = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if let heading = parse(headingText: text) { headings.append(heading) }
        }
        return headings
    }

    /// Reads one heading's text, or returns `nil` when it names no version.
    ///
    /// `## Contributing` and `## [Keep a Changelog](https://…)` both reach here, and neither is
    /// a release. The test is deliberately narrow — a label is a version only if it is digits
    /// and dots after an optional `v` — because a false positive produces a definition for a
    /// tag nobody ever cut.
    static func parse(headingText text: String) -> VersionHeading? {
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let label = String(text[text.index(after: text.startIndex)..<close])
            if label.lowercased() == "unreleased" {
                return VersionHeading(
                    label: label, version: "", isBracketed: true, isUnreleased: true)
            }
            guard let version = version(of: label) else { return nil }
            return VersionHeading(
                label: label, version: version, isBracketed: true, isUnreleased: false)
        }
        // An unbracketed heading is `## 2.0.1` or `## 2.0.1 — 2026-07-27`; take the first word.
        guard let first = text.split(separator: " ").first,
              let version = version(of: String(first))
        else {
            return nil
        }
        return VersionHeading(
            label: String(first), version: version, isBracketed: false, isUnreleased: false)
    }

    /// The bare version in a label, or `nil` when the label is not one.
    static func version(of label: String) -> String? {
        var candidate = label.trimmingCharacters(in: .whitespaces)
        if candidate.hasPrefix("v") || candidate.hasPrefix("V") { candidate.removeFirst() }
        guard !candidate.isEmpty else { return nil }
        let components = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            return nil
        }
        return candidate
    }
}
