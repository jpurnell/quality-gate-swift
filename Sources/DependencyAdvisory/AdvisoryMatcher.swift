import Foundation

/// Decides whether an advisory reaches a pin: is it the same package, and is the version in range.
///
/// ## Why matching is local and not the API's
///
/// Each of these produced a wrong answer on real data before it produced a right one
/// (`AnAdvisoryIsADatedFact.md` §2):
///
/// - **The live API is case-sensitive and lockfiles are not consistent about case.** Querying
///   `github.com/marmelroy/zip` returns nothing; `github.com/marmelroy/Zip` returns
///   GHSA-g454-wj9r-jpg4. A lockfile records whatever the manifest typed. So names are compared
///   case-insensitively, on both sides.
/// - **Some records do not name their package by URL.** GHSA-q3g2-m552-3r9c gives
///   `swift-nio-http2`; queried by URL, the API does not return it. So a name with no `/` is
///   compared to the pin's last path component, and reported under its own rule id.
/// - **A two-component version is not SemVer.** See ``AdvisoryVersion``. A bound that cannot be
///   parsed makes the range unevaluable, never open.
enum AdvisoryMatcher {

    // MARK: - Identity

    /// A repository location reduced to `host/path`: no scheme, no credentials, no `.git`, no
    /// trailing slash. Case is kept — it is folded where two identities are compared, so a
    /// finding can still show the pin as the lockfile spells it.
    static func identity(ofLocation location: String) -> String {
        var rest = Substring(location.trimmingCharacters(in: .whitespacesAndNewlines))

        if let scheme = rest.range(of: "://") {
            rest = rest[scheme.upperBound...]
            // Credentials sit before the last `@` of the authority, which ends at the first `/`.
            let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
            if let at = rest[..<authorityEnd].lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        } else if let colon = rest.firstIndex(of: ":"), let at = rest[..<colon].lastIndex(of: "@"),
                  !rest[..<colon].contains("/") {
            // The scp-like form `git@host:owner/repo`.
            rest = rest[rest.index(after: at)..<colon] + "/" + rest[rest.index(after: colon)...]
        }

        while rest.hasSuffix("/") { rest = rest.dropLast() }
        if rest.lowercased().hasSuffix(".git") { rest = rest.dropLast(4) }
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        return String(rest)
    }

    /// How an advisory's package name was matched to a pin.
    enum MatchKind: Sendable, Equatable {
        /// The advisory names the pin's repository.
        case url
        /// The advisory gives a bare name equal to the pin's last path component. A weaker
        /// match, and the reader should be able to see that it is; it is not a weaker finding.
        case name
    }

    /// Whether an advisory's package `name` is the package at `pinIdentity`, and how.
    static func match(pinIdentity: String, advisoryName name: String) -> MatchKind? {
        let pin = pinIdentity.lowercased()
        let advisory = identity(ofLocation: name).lowercased()
        guard advisory.contains("/") else {
            return pin.split(separator: "/").last.map(String.init) == advisory ? .name : nil
        }
        return spellings(of: pin).contains(advisory) ? .url : nil
    }

    /// Packages that moved from `github.com/apple/` to `github.com/swiftlang/`.
    ///
    /// An advisory filed under one organisation does not name a pin under the other, and both
    /// spellings of `swift-docc-plugin` are pinned across this portfolio. This is a list: it
    /// will go stale, and it is reviewed with the rule (`SecurityRuleManifest`, 180 days).
    static let movedToSwiftlang: Set<String> = [
        "indexstore-db", "sourcekit-lsp", "swift-cmark", "swift-corelibs-foundation",
        "swift-corelibs-libdispatch", "swift-corelibs-xctest", "swift-docc", "swift-docc-plugin",
        "swift-docc-symbolkit", "swift-driver", "swift-experimental-string-processing",
        "swift-format", "swift-foundation", "swift-foundation-icu", "swift-llbuild", "swift-lmdb",
        "swift-markdown", "swift-package-manager", "swift-syntax", "swift-testing",
        "swift-tools-support-core", "swift-toolchain-sqlite",
    ]

    /// Every lower-cased identity `pin` is known by: itself, and the other organisation's
    /// spelling when the package is one that moved.
    static func spellings(of pin: String) -> Set<String> {
        var result: Set<String> = [pin]
        for (from, to) in [("github.com/apple/", "github.com/swiftlang/"), ("github.com/swiftlang/", "github.com/apple/")]
        where pin.hasPrefix(from) {
            let package = String(pin.dropFirst(from.count))
            if movedToSwiftlang.contains(package) { result.insert(to + package) }
        }
        return result
    }

    // MARK: - Versions

    /// What one affected entry says about one version.
    enum Verdict: Sendable, Equatable {
        /// The version is affected.
        case affected(Hit)
        /// The version is outside every range and not listed.
        case clear
        /// A bound could not be parsed, so the entry says nothing either way.
        case unevaluable(bound: String)
    }

    /// The part of a range a version fell in.
    struct Hit: Sendable, Equatable {
        /// The range in words: `< 2.100.0`, `>= 4.0.0, < 4.3.1`, `<= 2.1.2`.
        let range: String
        /// The version that fixes it, when the range has one.
        let fixed: String?
    }

    /// Evaluates `version` against one affected entry.
    ///
    /// `SEMVER` and `ECOSYSTEM` ranges are walked by their events; `GIT` ranges name commits and
    /// are skipped, as no version can be compared to one (the Swift export has none). A version
    /// listed in `versions` is affected whatever the ranges say.
    static func evaluate(_ version: AdvisoryVersion, text: String, against affected: Advisory.Affected) -> Verdict {
        var unevaluable: String?
        for range in affected.ranges where range.type == "SEMVER" || range.type == "ECOSYSTEM" {
            switch evaluate(version, in: range) {
            case .affected(let hit): return .affected(hit)
            case .unevaluable(let bound): unevaluable = unevaluable ?? bound
            case .clear: continue
            }
        }
        if affected.versions.contains(where: { $0 == text || AdvisoryVersion($0) == version }) {
            return .affected(Hit(range: "the listed version \(text)", fixed: nil))
        }
        return unevaluable.map { .unevaluable(bound: $0) } ?? .clear
    }

    /// One event with its version parsed. `introduced: "0"` is the beginning of time.
    private struct Bound {
        let kind: String
        let text: String
        let version: AdvisoryVersion?
        var isOrigin: Bool { kind == "introduced" && text == "0" }
    }

    /// Walks one range the way the OSV schema specifies: events in version order, `introduced`
    /// turning the flag on, `fixed` and `last_affected` turning it off.
    private static func evaluate(_ version: AdvisoryVersion, in range: Advisory.Range) -> Verdict {
        var bounds: [Bound] = []
        for event in range.events where ["introduced", "fixed", "last_affected"].contains(event.kind) {
            let bound = Bound(kind: event.kind, text: event.value, version: AdvisoryVersion(event.value))
            // A bound that is not a version makes the whole range unevaluable — never open.
            guard bound.isOrigin || bound.version != nil else { return .unevaluable(bound: event.value) }
            bounds.append(bound)
        }
        bounds = stablySorted(bounds)

        var lower: Bound?
        for bound in bounds {
            if bound.kind == "introduced", reaches(version, bound) {
                lower = bound
            } else if bound.kind == "fixed", let fixed = bound.version, version >= fixed {
                lower = nil
            } else if bound.kind == "last_affected", let last = bound.version, version > last {
                lower = nil
            }
        }
        guard let lower else { return .clear }
        return .affected(hit(from: lower, for: version, in: bounds))
    }

    private static func reaches(_ version: AdvisoryVersion, _ introduced: Bound) -> Bool {
        guard let start = introduced.version, !introduced.isOrigin else { return true }
        return version >= start
    }

    /// Orders bounds by version, keeping published order between equals. `sort` makes no
    /// stability promise, so the original index breaks ties explicitly.
    private static func stablySorted(_ bounds: [Bound]) -> [Bound] {
        bounds.enumerated().sorted { left, right in
            switch (left.element.isOrigin ? nil : left.element.version, right.element.isOrigin ? nil : right.element.version) {
            case (nil, nil): return left.offset < right.offset
            case (nil, .some): return true
            case (.some, nil): return false
            case (let leftVersion?, let rightVersion?):
                return leftVersion == rightVersion ? left.offset < right.offset : leftVersion < rightVersion
            }
        }.map(\.element)
    }

    /// Describes the segment `version` fell in, and names what closes it.
    private static func hit(from lower: Bound, for version: AdvisoryVersion, in bounds: [Bound]) -> Hit {
        let upper = bounds.first { bound in
            guard let limit = bound.version else { return false }
            return (bound.kind == "fixed" && limit > version) || (bound.kind == "last_affected" && limit >= version)
        }
        var parts: [String] = []
        if !lower.isOrigin { parts.append(">= \(lower.text)") }
        if let upper { parts.append(upper.kind == "fixed" ? "< \(upper.text)" : "<= \(upper.text)") }
        return Hit(
            range: parts.isEmpty ? "all versions" : parts.joined(separator: ", "),
            fixed: upper?.kind == "fixed" ? upper?.text : nil)
    }
}
