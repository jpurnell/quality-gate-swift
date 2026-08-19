import Foundation

/// A named selection of checkers, derived from what each checker declares.
///
/// ## Why derived rather than listed
///
/// Membership is computed from ``QualityChecker/kind`` and ``QualityChecker/effect``, never
/// from a list of ids held beside the registry. A list fails silently whichever way it is
/// written: an inclusion list drops a newly added checker out of every profile, and an
/// exclusion list quietly admits a new documentation checker into ``code``. Neither failure
/// announces itself, and a survey whose coverage changed without anyone noticing still
/// produces numbers that look comparable to the previous one.
///
/// Because the requirements have no defaults, a checker cannot be added without being
/// classified, so a profile cannot drift from the registry. That is the whole design.
///
/// ## Intended use
///
/// Surveying repositories this project does not own, to find out where the checkers are wrong.
/// Dogfooding cannot discover a rule that misjudges an idiom this project never writes — a
/// single run against an unfamiliar package produced two checker defects with fixtures
/// attached, and neither was reachable from inside.
public enum CheckerProfile: String, Sendable, Codable, CaseIterable, Equatable {

    /// Checkers that judge the source on its own terms, write nothing, and run nothing.
    ///
    /// The safe profile to aim at a repository nobody here owns: every finding is one whose
    /// author would recognise it as being about their code, running it leaves no trace, and
    /// **the surveyed package's own code is never executed** — no compiler is invoked and no
    /// test suite is run.
    ///
    /// That last clause was added after the profile was observed running a stranger's test
    /// suite for ten minutes. It had always been true of what the profile *reported* and never
    /// of what it *ran*.
    case code

    /// Checkers that judge documentation, and write nothing.
    case docs

    /// Every registered checker, whatever it judges and whatever it leaves behind.
    ///
    /// Equivalent to `--check all`, and named so the profile vocabulary is complete rather
    /// than having a hole where "everything" should be.
    case all

    /// Whether `checker` belongs to this profile.
    ///
    /// - Parameter checker: Any registered checker.
    /// - Returns: `true` when the checker's declared kind and effect both qualify.
    public func includes(_ checker: any QualityChecker) -> Bool {
        switch self {
        case .all:
            return true
        case .code:
            // Three axes, because two were not enough. `build`, `test` and `xcode-build` are
            // code-kind and genuinely read-only — compilation output is deliberately not a
            // write — and are still the three a survey must not run, because `test` executes
            // the surveyed package's suite. Alamofire's makes real network calls and ran for
            // ten minutes before being stopped; without them, nine repositories and 2,120 files
            // finish in 69 seconds.
            return checker.kind == .code
                && checker.effect == .readOnly
                && !checker.executesProjectCode
        case .docs:
            return checker.kind == .documentation && checker.effect == .readOnly
        }
    }

    /// The ids this profile selects, in registry order.
    ///
    /// Registry order is preserved because it is the order findings are reported in, and a
    /// profile that reordered the output would make two runs harder to compare for no reason.
    ///
    /// - Parameter checkers: The registry, in its own order.
    /// - Returns: The selected ids.
    public func checkerIDs(from checkers: [any QualityChecker]) -> [String] {
        checkers.filter { includes($0) }.map(\.id)
    }

    /// Why a checker is not in this profile, for a reader who expected it to be.
    ///
    /// A profile that silently runs 29 of 45 invites the question "where did the rest go?", and
    /// the answer is more useful than a count. Returns `nil` when the checker *is* included.
    ///
    /// - Parameter checker: Any registered checker.
    /// - Returns: A short phrase naming the reason, or `nil`.
    public func exclusionReason(for checker: any QualityChecker) -> String? {
        guard !includes(checker) else { return nil }
        if checker.effect != .readOnly {
            return "writes (\(checker.effect.rawValue))"
        }
        return "judges \(checker.kind.rawValue)"
    }
}
