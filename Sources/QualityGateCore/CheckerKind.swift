import Foundation

/// What a checker's findings are *about*.
///
/// ## Why this is not `CheckerCategory`
///
/// ``CheckerCategory`` groups the README's reference table — an editorial judgment about what
/// reads well. This answers a different question: whose standard is being applied. The two do
/// not carve at the same joint, and the difference is load-bearing. `consistency` and `status`
/// are `specialty` under the editorial grouping and sit beside ordinary code checkers there;
/// here they are ``institutional``, because pointing them at a repository that is not ours
/// produces findings about *us*.
///
/// ## Why a marker rather than a list
///
/// Profile membership was first drafted as a list of ids maintained beside the registry. Both
/// spellings of that list fail silently, in opposite directions: an inclusion list drops a
/// newly added checker out of every survey, and an exclusion list quietly admits a new
/// documentation checker into the code profile. Neither failure announces itself, and a survey
/// whose coverage has silently changed is worse than no survey, because its numbers still
/// look comparable.
///
/// Declaring the kind on the checker removes the second source of truth. A profile is then a
/// filter over the registry and cannot drift from it.
///
/// ## No default, deliberately
///
/// ``QualityChecker/kind`` has no extension default, for the reason ``QualityChecker/summary``
/// and ``QualityChecker/hermeticity`` have none: the runner holds checkers as
/// `any QualityChecker`, so a witness supplied only by an extension dispatches statically to
/// the default and silently classifies every checker whose author never considered the
/// question. A new checker should fail to compile until someone decides what it judges.
public enum CheckerKind: String, Sendable, Codable, CaseIterable, Equatable {

    /// Judges the source on its own terms — the finding would be a finding in any repository.
    ///
    /// Force unwraps, data races, unbounded recursion, dead code, escaping pointers. A stranger
    /// reading one of these learns something about their code, not about our conventions.
    case code

    /// Judges documentation: that it exists, builds, compiles, runs, and matches its figures.
    case documentation

    /// Judges a convention this project defined, or a value it holds.
    ///
    /// The findings are real, and they are only meaningful where the convention has been
    /// adopted. `doc-generated` reads as documentation and belongs here instead: it checks
    /// *this project's* generated regions, and means nothing in a repository that has never
    /// used the delimiters.
    ///
    /// `context` belongs here for the second reason rather than the first. It scans Swift
    /// source, which makes it look like ``code``, but what it reports — consent guards,
    /// unguarded analytics, surveillance patterns — is a judgment about someone's product
    /// decisions. Applied to an unfamiliar repository that is not a defect report, it is an
    /// opinion nobody asked for.
    case convention

    /// Measures the run against out-of-tree institutional state.
    ///
    /// `consistency` scores against our pulse; `status` reads our Master Plan. Run against
    /// another party's repository these do not describe their code at all — and they report
    /// *findings* rather than errors, so nothing announces the mistake. This is the
    /// classification a survey most needs to get right.
    case institutional
}
