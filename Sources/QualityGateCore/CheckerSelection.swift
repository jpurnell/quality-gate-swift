import Foundation

/// Resolves which checkers should run for a given invocation.
///
/// Extracted from the CLI so the selection rules are unit-testable and consistent
/// across entry points.
///
/// ## No destructive checkers
///
/// Selection no longer carries a denylist of tree-mutating checkers. Cleanup moved to the
/// `quality-gate clean` subcommand and off the `QualityChecker` protocol entirely, so
/// "run all checks" is non-destructive because nothing registered can mutate the tree —
/// not because a hardcoded set of ids is held back. See `DiskCleaner`.
public enum CheckerSelection {

    /// Resolve the ordered list of checker ids to run.
    ///
    /// The unvalidated form: it normalises comma lists and applies the selection rules, and
    /// returns whatever ids result — including ones that name no checker. The CLI's main
    /// run uses ``select(_:allIDs:)``, which validates as well.
    ///
    /// - Parameters:
    ///   - requested: Values from `--check`. May contain the sentinel `"all"` and/or
    ///     explicit checker ids.
    ///   - excluded: Exclusions that decline a checker from `--check all` and from the
    ///     default set, but do not refuse an explicit `--check` — the meaning of
    ///     `Configuration.excludedCheckers`.
    ///   - configuredEnabled: `Configuration.enabledCheckers` (from `.quality-gate.yml`).
    ///   - configuredIncluded: `Configuration.includedCheckers` — ids added to the default
    ///     set (or to `configuredEnabled` when that is set). The way to opt one checker in
    ///     without `enabledCheckers: [all]`, which opts in every convention-gated one too.
    ///     Has no effect on `--check all` or an explicit `--check`, and loses to an
    ///     exclusion, so `--exclude` stays a working escape hatch.
    ///   - full: The `--full` flag; opts `xcode-build` back into the default set.
    ///   - allIDs: All registered checker ids, in registry (output) order.
    /// - Returns: The checker ids to run, preserving `allIDs` order where applicable.
    public static func resolve(
        requested: [String],
        excluded: [String],
        configuredEnabled: [String],
        configuredIncluded: [String] = [],
        full: Bool,
        allIDs: [String]
    ) -> [String] {
        baseIDs(
            Request(
                requested: requested,
                configuredEnabled: configuredEnabled,
                configuredExcluded: excluded,
                configuredIncluded: configuredIncluded,
                full: full
            ).normalised,
            allIDs: allIDs,
            applyingArgumentExclusions: true)
    }

    // MARK: - Normalise

    /// Splits every value on commas, trims whitespace, and drops empty tokens.
    ///
    /// `--check` is parsed `.upToNextOption`, so `--check a b` and `--check a --check b`
    /// arrive as two values and `--check a,b` arrives as the one string `"a,b"` — which
    /// named no checker, ran nothing, and exited 0. The comma form is not an idiosyncrasy:
    /// the documented security-audit invocation is
    /// `--check safety,fp-safety,stochastic-determinism`. Checker ids never contain a
    /// comma, so the split is unambiguous.
    ///
    /// - Parameter values: Raw values from a flag or a configuration list.
    /// - Returns: One id per element, in order.
    public static func normalise(_ values: [String]) -> [String] {
        values.flatMap { value in
            value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    // MARK: - Validated selection

    /// Everything that decides which checkers run.
    public struct Request: Sendable, Equatable {
        /// Values from `--check`.
        public var requested: [String]
        /// Values from `--exclude`. Narrows every selection, an explicit `--check` included.
        public var excluded: [String]
        /// `Configuration.enabledCheckers`.
        public var configuredEnabled: [String]
        /// `Configuration.excludedCheckers`. Declines a checker from `--check all` and from
        /// the default set; does not refuse an explicit `--check`.
        public var configuredExcluded: [String]
        /// `Configuration.includedCheckers`.
        public var configuredIncluded: [String]
        /// The `--full` flag.
        public var full: Bool
        /// The ids a `--profile` selects, or `nil` when no profile was given.
        public var profileBase: [String]?

        /// Creates a request.
        ///
        /// - Parameters:
        ///   - requested: Values from `--check`.
        ///   - excluded: Values from `--exclude`.
        ///   - configuredEnabled: `Configuration.enabledCheckers`.
        ///   - configuredExcluded: `Configuration.excludedCheckers`.
        ///   - configuredIncluded: `Configuration.includedCheckers`.
        ///   - full: The `--full` flag.
        ///   - profileBase: The ids a `--profile` selects; `nil` without one.
        public init(
            requested: [String] = [],
            excluded: [String] = [],
            configuredEnabled: [String] = [],
            configuredExcluded: [String] = [],
            configuredIncluded: [String] = [],
            full: Bool = false,
            profileBase: [String]? = nil
        ) {
            self.requested = requested
            self.excluded = excluded
            self.configuredEnabled = configuredEnabled
            self.configuredExcluded = configuredExcluded
            self.configuredIncluded = configuredIncluded
            self.full = full
            self.profileBase = profileBase
        }

        /// This request with every id list split on commas.
        var normalised: Request {
            Request(
                requested: CheckerSelection.normalise(requested),
                excluded: CheckerSelection.normalise(excluded),
                configuredEnabled: CheckerSelection.normalise(configuredEnabled),
                configuredExcluded: CheckerSelection.normalise(configuredExcluded),
                configuredIncluded: CheckerSelection.normalise(configuredIncluded),
                full: full,
                profileBase: profileBase)
        }
    }

    /// A selection the gate can honour.
    public struct Selection: Sendable, Equatable {
        /// The checker ids to run. Never empty.
        public let ids: [String]
        /// One-line notices about values that were accepted but did nothing, for stderr.
        public let notices: [String]
    }

    /// Ids that used to be checkers, and what replaced each.
    ///
    /// A table rather than a guess: a removed checker gets an entry, is refused with
    /// directions in `--check`, and is accepted with a notice in an exclusion. An id that
    /// was never a checker has no entry and breaks the run.
    static let retiredIDs: [String: String] = ["disk-clean": "quality-gate clean"]

    /// The sentinel that selects every registered checker.
    static let allSentinel = "all"

    /// Resolves and validates a selection.
    ///
    /// A selection the gate cannot honour is an error, not a no-op. Before this, an id
    /// that named no checker was filtered out silently: `--check bogus` printed
    /// `No checkers enabled. Nothing to do.` and exited 0, `--check recursion --check bogus`
    /// ran `recursion` alone and passed, and a typo in `enabledCheckers` ran nothing.
    ///
    /// Three rules, in order:
    ///
    /// 1. **Retired ids.** In `--check` or `enabledCheckers`, refused with the replacement
    ///    named. In an exclusion, accepted with a notice.
    /// 2. **Unknown ids.** In `--check` or `--exclude`, a usage error — and one bad id
    ///    among good ones refuses the whole selection, because "ran 2 of the 3 I asked for
    ///    and passed" is the silent drop. In `enabledCheckers`, a configuration error,
    ///    checked only when that list is what selects. In `excludedCheckers` or
    ///    `includedCheckers`, a notice.
    /// 3. **Empty selections.** Never returned; thrown, naming what emptied it.
    ///
    /// `--exclude` narrows an explicit `--check`; `excludedCheckers` does not, so a
    /// configuration file cannot make a checker unexaminable.
    ///
    /// - Parameters:
    ///   - request: The flags and configuration that decide the selection.
    ///   - allIDs: All registered checker ids, in registry (output) order.
    /// - Returns: The ids to run, with any notices.
    /// - Throws: ``CheckerSelectionError`` when the selection cannot be honoured.
    public static func select(
        _ request: Request, allIDs: [String]
    ) throws(CheckerSelectionError) -> Selection {
        let request = request.normalised
        let known = Set(allIDs)
        var notices: [String] = []

        // `enabledCheckers` selects only when neither `--check` nor `--profile` does. A
        // request the arguments fully specify is not refused over a list it never read.
        let configurationSelects = request.requested.isEmpty && request.profileBase == nil

        // 1. Retired ids, ahead of validation so the replacement is what the user reads.
        let selecting = request.requested + (configurationSelects ? request.configuredEnabled : [])
        if let retired = selecting.first(where: { retiredIDs[$0] != nil }),
           let replacement = retiredIDs[retired] {
            throw .retired(retired, replacement: replacement)
        }
        for (id, flag) in request.excluded.map({ ($0, "--exclude") })
            + request.configuredExcluded.map({ ($0, "excludedCheckers") }) {
            if let replacement = retiredIDs[id] {
                notices.append(
                    "\(flag) '\(id)' is no longer a checker (it moved to `\(replacement)`); nothing to exclude.")
            }
        }

        // 2. Unknown ids.
        let unknownRequested = unique(request.requested.filter { $0 != allSentinel && !known.contains($0) })
        if !unknownRequested.isEmpty {
            throw .unknownCheckers(
                unknownRequested, suggestions: suggestions(for: unknownRequested, among: allIDs))
        }
        let unknownExcluded = unique(
            request.excluded.filter { !known.contains($0) && retiredIDs[$0] == nil })
        if !unknownExcluded.isEmpty {
            throw .unknownExclusions(
                unknownExcluded, suggestions: suggestions(for: unknownExcluded, among: allIDs))
        }
        if configurationSelects {
            let unknownEnabled = unique(
                request.configuredEnabled.filter { $0 != allSentinel && !known.contains($0) })
            if !unknownEnabled.isEmpty {
                throw .unknownConfigured(
                    unknownEnabled, key: "enabledCheckers",
                    suggestions: suggestions(for: unknownEnabled, among: allIDs))
            }
        }
        for (ids, key) in [
            (request.configuredExcluded, "excludedCheckers"),
            (request.configuredIncluded, "includedCheckers"),
        ] {
            for id in unique(ids) where !known.contains(id) && retiredIDs[id] == nil {
                notices.append("configuration: \(key) names '\(id)', which is not a checker; ignored.")
            }
        }

        // 3. Resolve, and refuse an empty result.
        let ids = baseIDs(request, allIDs: allIDs, applyingArgumentExclusions: true)
        guard ids.isEmpty else { return Selection(ids: ids, notices: notices) }

        if let profileBase = request.profileBase,
           profileBase.isEmpty && request.requested.allSatisfy({ $0 == allSentinel }) {
            throw .emptySelection(.profile)
        }
        // Something was selected before `--exclude` was applied, so the arguments emptied
        // it. Otherwise the configuration did.
        let beforeArgumentExclusions = baseIDs(request, allIDs: allIDs, applyingArgumentExclusions: false)
        throw .emptySelection(beforeArgumentExclusions.isEmpty ? .configuration : .allExcluded)
    }

    // MARK: - Resolution

    /// The selection rules, over a normalised request. Validates nothing.
    private static func baseIDs(
        _ request: Request, allIDs: [String], applyingArgumentExclusions: Bool
    ) -> [String] {
        let argumentExcluded = Set(applyingArgumentExclusions ? request.excluded : [])
        let excludeSet = argumentExcluded.union(request.configuredExcluded)
        let requested = request.requested
        let configuredEnabled = request.configuredEnabled
        let configuredIncluded = request.configuredIncluded

        // `--profile` supplies the base selection; `--check` and `--exclude` compose on
        // top, so `--profile code --exclude complexity` means what it looks like. The
        // profile filters on what each checker *declares*, so `excludedCheckers` — written
        // for the default set — is not consulted.
        if let profileBase = request.profileBase {
            let base = Set(profileBase)
            let explicit = Set(requested.filter { $0 != allSentinel })
            return allIDs.filter {
                (base.contains($0) || explicit.contains($0)) && !argumentExcluded.contains($0)
            }
        }

        if requested.contains(allSentinel) {
            return allIDs.filter { !excludeSet.contains($0) }
        } else if !requested.isEmpty {
            // Explicit ids run as requested, minus what `--exclude` named. A configured
            // exclusion does not apply: naming a checker is a request to see what it says.
            return unique(requested).filter { !argumentExcluded.contains($0) }
        } else if !configuredEnabled.isEmpty {
            // `all` means the same thing here as it does on the command line. Without this
            // the obvious repair for a dropped `enabledCheckers` key —
            //
            //     enabledCheckers:
            //       - all
            //
            // returns ["all"], matches no checker id, and runs *nothing*, silently. A
            // reader correcting one invisible misconfiguration would land one step deeper
            // into the same failure, and the run would still print PASSED.
            if configuredEnabled.contains(allSentinel) {
                return allIDs.filter { !excludeSet.contains($0) }
            }
            let added = configuredIncluded.filter { !configuredEnabled.contains($0) }
            return (configuredEnabled + added).filter { !excludeSet.contains($0) }
        } else {
            // Default (no --check, no config): everything except the opt-in checkers.
            //
            // `xcode-build` opts out on cost.
            //
            // `doc-code` used to opt out on *convention*, and the reasoning is kept here
            // rather than deleted, because it was right at the time: the rule holds an
            // article to being one compilable program, which a repository has to adopt
            // before the verdict means anything. Imposed by default it reported a wall of
            // true findings about documentation nobody had agreed to write that way — 76 of
            // them against this package — and a gate that is red on arrival gets skipped,
            // which costs more than the rule buys.
            //
            // That bar has now been met, which is why it is default-on: the catalogue is at
            // 0 findings across 50 articles and 152 fences, with **zero**
            // `<!-- docs:illustrative -->` markers. The convention was adopted by repairing
            // the documentation, not by lowering the rule. Note that the wall of 76 was also
            // partly the checker's own fault — it was silently failing to typecheck anything
            // at all until the module-import barrier was fixed, so some of what looked like
            // convention cost was a tooling defect wearing its costume.
            //
            // `doc-run` and `doc-claims` stay opt-in on a *stronger* convention still. Rung 2
            // requires an article to run as one program, top to bottom, without a trap;
            // rung 3 requires its documented figures to match what that program computes.
            // Each is red on arrival for a catalogue that has not done the remediation, and
            // the rollout shape that works is rule-and-remediation in one push — which is
            // exactly the shape `doc-code` has just finished walking, so the precedent for
            // promoting them later is now on the record rather than hypothetical.
            //
            // `doc-comment-code` is opt-in. It was promoted into the default set on
            // 2026-08-27 and reverted the same night, and the reason is worth more than the
            // one-line diff: the promotion was justified by a survey that did not cover the
            // fleet it claimed to.
            //
            // What the promoting commit recorded was "39 gate-configured repositories
            // surveyed, 5 red, 60 errors, all repaired first". The number 39 was real; the
            // word "all" was not. The survey globbed `Swift/*/.quality-gate.yml` — one
            // directory, one level deep — while `find` over the same tree returns 86. The
            // 47 it missed were every repository living in a subdirectory: `Tools/`,
            // `harbor/`, `Playgrounds/Math/`, `Embedded/`, `Princeton/`.
            //
            // That blind spot was not random with respect to the answer. A full sweep after
            // the flip found 12 red repositories carrying 162 errors, and every single one
            // of them was in a subdirectory — five in `Tools/`, which is where this package
            // itself lives. The sampled 39 were green precisely because they were the
            // top-level packages that had already had attention paid to them.
            //
            // So the bar `doc-code` met is unchanged and still right — adopt the convention
            // by repairing the documentation, never by relaxing the rule. This rule has not
            // met it yet. Re-promoting takes a survey enumerated with `find`, not a glob,
            // and the 12 reds repaired first. Three of them (`BusinessMathPro`,
            // `swift-potrace`, `sicp-swift-companion`) are already done and stay done.
            //
            // Two findings from that sweep outlived the revert and are the reason it was
            // not a total loss:
            //
            // First, a survey run as `--check doc-comment-code` does not run `build`, and
            // this checker compiles against a built module rather than building one — so
            // every cold-`.build` repository reports SKIPPED and reads as clean. Three
            // "clean" repositories were red once `build` ran first. That is why
            // `module-unavailable` is now a warning rather than a note, and why any future
            // survey must invoke `--check build --check doc-comment-code`.
            //
            // Second, one repository cannot be evaluated at all. `Ignite` depends on
            // swift-markdown, whose C target `cmark_gfm_extensions` the fence compile cannot
            // reach; compilation stops at that barrier before a single fence is read, and
            // 16 of its 17 findings are that barrier restated. Its docs are not implicated.
            // It carries `excludedCheckers: [doc-comment-code]` until the fence compile
            // learns to feed a package's C-target module maps to the compiler — which is the
            // real fix, and is not this change. That entry stays load-bearing even while the
            // rule is opt-in, because `--check all` still selects it and the pre-push hook
            // runs `--check all`.
            //
            // `dependency-advisory-drift` is opt-in on a different ground from the rest: it is
            // the one checker that opens a connection. `dependency-advisory` and
            // `dependency-advisory-freshness` are in the default set and read only a snapshot
            // and the clock; the live comparison belongs in a scheduled job, not in every
            // pre-commit hook, where it would add a network round trip — and, offline, a
            // ten-second timeout — to every commit in every repository.
            var optOut: Set<String> = [
                "xcode-build", "doc-run", "doc-claims", "doc-comment-code", "doc-generated",
                "dependency-advisory-drift",
            ]
            if request.full { optOut.remove("xcode-build") }
            optOut.subtract(configuredIncluded)
            // `--exclude` is honoured here too, which it was not before. While `doc-code` was
            // opt-in that gap was invisible: nothing in the default set was worth excluding,
            // so `quality-gate --exclude doc-code` silently doing nothing cost nobody
            // anything. Promoting a checker into the default set is exactly what makes the
            // escape hatch load-bearing — a rule you cannot decline with the obvious flag is
            // a rule that gets declined by not running the gate.
            return allIDs.filter { !optOut.contains($0) && !excludeSet.contains($0) }
        }
    }

    /// `ids` without repeats, first occurrence kept.
    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Suggestions

    /// For each unknown id, the registered id it most plausibly meant.
    ///
    /// An id is suggested only when it is within a third of the typo's length (at most two
    /// edits), so `recursoin` finds `recursion` and `bogus` finds nothing.
    static func suggestions(for unknown: [String], among allIDs: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for id in unknown {
            let allowed = max(1, min(2, id.count / 3))
            var best: (id: String, distance: Int)?
            for candidate in allIDs {
                let distance = editDistance(id, candidate)
                guard distance <= allowed else { continue }
                if let current = best, current.distance <= distance { continue }
                best = (candidate, distance)
            }
            if let best { result[id] = best.id }
        }
        return result
    }

    /// Levenshtein distance between two ids, computed iteratively over two rows.
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }
        var previous = Array(0...right.count)
        for (row, leftCharacter) in left.enumerated() {
            var current = [row + 1]
            current.reserveCapacity(right.count + 1)
            for (column, rightCharacter) in right.enumerated() {
                let substitution = previous[column] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(substitution, previous[column + 1] + 1, current[column] + 1))
            }
            previous = current
        }
        return previous[right.count]
    }
}

/// A checker selection the gate cannot honour.
public enum CheckerSelectionError: Error, Sendable, Equatable {

    /// What left a selection with nothing in it.
    public enum EmptyCause: Sendable, Equatable {
        /// `--exclude` removed everything the rest of the request selected.
        case allExcluded
        /// The configuration excludes everything it enables.
        case configuration
        /// The `--profile` matches no checker in this registry.
        case profile
    }

    /// `--check` names ids that are not checkers.
    case unknownCheckers([String], suggestions: [String: String])
    /// `--exclude` names ids that are not checkers.
    case unknownExclusions([String], suggestions: [String: String])
    /// A configuration key names ids that are not checkers.
    case unknownConfigured([String], key: String, suggestions: [String: String])
    /// The id was a checker once; `replacement` is the command that does its job now.
    case retired(String, replacement: String)
    /// The selection is valid and selects nothing.
    case emptySelection(EmptyCause)

    /// Whether the command line caused this, rather than the configuration.
    public var isUsageError: Bool {
        switch self {
        case .unknownCheckers, .unknownExclusions, .emptySelection(.allExcluded): true
        case .unknownConfigured, .retired, .emptySelection(.configuration), .emptySelection(.profile): false
        }
    }

    /// The process exit code: 64 (`EX_USAGE`) for a usage error, 1 otherwise.
    ///
    /// 64 is what this binary already returns for a malformed argument. Keeping "you asked
    /// wrongly" apart from "your code failed" lets a hook tell a broken invocation from a
    /// red gate.
    public var exitCode: Int32 {
        isUsageError ? 64 : 1
    }

    /// What to print.
    public var message: String {
        switch self {
        case .unknownCheckers(let ids, let suggestions):
            return Self.unknown(ids, suggestions) { "--check '\($0)' names no checker." }
                + "\nRun `quality-gate doctor` or `quality-gate --help` for the checkers this binary has."
                + "\nNothing was run."
        case .unknownExclusions(let ids, let suggestions):
            return Self.unknown(ids, suggestions) { "--exclude '\($0)' names no checker." }
                + "\nRun `quality-gate doctor` or `quality-gate --help` for the checkers this binary has."
                + "\nNothing was run."
        case .unknownConfigured(let ids, let key, let suggestions):
            return Self.unknown(ids, suggestions) {
                "configuration: \(key) names '\($0)', which is not a checker."
            } + "\nNothing was run."
        case .retired(let id, let replacement):
            return "`--check \(id)` has moved: run `\(replacement)` instead."
        case .emptySelection(.allExcluded):
            return "ERROR: --exclude removes every checker this run selected. Nothing was run, "
                + "and a run that examined nothing has not passed."
        case .emptySelection(.configuration):
            return "ERROR: configuration: the checkers it enables are all excluded by "
                + "excludedCheckers. Nothing was run, and a run that examined nothing has not passed."
        case .emptySelection(.profile):
            return "ERROR: --profile selects no checker in this binary's registry. Nothing was "
                + "run, and a run that examined nothing has not passed."
        }
    }

    private static func unknown(
        _ ids: [String], _ suggestions: [String: String], line: (String) -> String
    ) -> String {
        ids.map { id in
            "ERROR: " + line(id) + (suggestions[id].map { " Did you mean '\($0)'?" } ?? "")
        }.joined(separator: "\n")
    }
}
