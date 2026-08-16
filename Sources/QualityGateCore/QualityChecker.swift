import Foundation
@_exported import QualityGateTypes

/// Protocol that all quality checkers must implement.
///
/// Each checker is responsible for a specific category of quality checks,
/// such as building, testing, safety auditing, or documentation linting.
///
/// ## Implementing a Checker
///
/// ```swift
/// struct MyChecker: QualityChecker {
///     let id = "my-checker"
///     let name = "My Custom Checker"
///     let summary = "The findings this checker reports, in one noun phrase"
///     let category = CheckerCategory.codeHygiene
///     let kind = CheckerKind.code
///     let effect = CheckerEffect.readOnly
///
///     func check(configuration: Configuration) async throws -> CheckResult {
///         // Perform checks...
///         return CheckResult(
///             checkerId: id,
///             status: .passed,
///             diagnostics: [],
///             duration: .seconds(1)
///         )
///     }
/// }
/// ```
public protocol QualityChecker: Sendable {

    /// Unique identifier for this checker.
    ///
    /// Used in configuration files and CLI arguments to reference this checker.
    /// Convention: lowercase with hyphens (e.g., "doc-lint", "safety").
    var id: String { get }

    /// Human-readable name for display.
    ///
    /// Shown in terminal output and reports.
    var name: String { get }

    /// One sentence: what this checker finds.
    ///
    /// This is the description column of `README.md`'s checker reference — the column a reader
    /// actually uses — and it is a protocol requirement rather than a convention for one
    /// reason: it used to live only in the README, and four checkers shipped without anyone
    /// adding a row. The sentence now lives beside the ``id`` it describes, so forgetting it is
    /// a compile error instead of a documentation error.
    ///
    /// Deliberately has no default. An extension-only default would dispatch statically through
    /// `any QualityChecker` and silently supply an empty description for every checker that
    /// forgot one, which is the failure this requirement exists to make impossible.
    ///
    /// Write it as a noun phrase naming the findings, not a sentence about the checker:
    /// *"Force unwraps, force casts, `try!`, `fatalError`"*, not *"This checker looks for…"*.
    var summary: String { get }

    /// Which section of the README's checker reference this belongs under.
    ///
    /// An editorial judgment, frozen into a type on purpose — see ``CheckerCategory``.
    var category: CheckerCategory { get }

    /// What this checker's findings are *about* — see ``CheckerKind``.
    ///
    /// Distinct from ``category``, which groups the README for readability. This answers whose
    /// standard is being applied, and it is what `--profile` filters on: a checker that judges
    /// our conventions or scores against our institutional pulse tells a stranger's repository
    /// nothing about itself.
    ///
    /// No default, for the reason ``summary`` has none — a witness supplied only by an
    /// extension dispatches statically through `any QualityChecker` and would classify every
    /// checker whose author never considered the question.
    var kind: CheckerKind { get }

    /// What this checker leaves behind — see ``CheckerEffect``.
    ///
    /// Separate from ``kind`` because a checker can judge code correctly and still write
    /// something, and a survey profile pointed at repositories nobody here owns needs to know
    /// that independently of what the checker judges.
    ///
    /// No default: a checker that writes and forgets to declare it is exactly the failure this
    /// prevents, and ``CheckerEffect/readOnly`` is what such a checker would inherit.
    var effect: CheckerEffect { get }

    /// Run the quality check and return results.
    ///
    /// - Parameter configuration: Project-specific configuration.
    /// - Returns: The check result with status and diagnostics.
    /// - Throws: `QualityGateError` if the check cannot be completed.
    func check(configuration: Configuration) async throws -> CheckResult

    /// Whether this checker is safe to run concurrently with other checkers.
    ///
    /// Defaults to `true` (pure AST/file analysis is read-only and parallel-safe).
    /// Checkers that spawn `swift build`/`swift test` (locking the SwiftPM `.build`
    /// directory) or mutate the build tree must return `false` so the runner executes
    /// them sequentially, outside the concurrent task group.
    var isParallelSafe: Bool { get }

    /// What this checker's verdict depends on beyond the working tree.
    ///
    /// Defaults to ``Hermeticity/hermetic``. Checkers whose findings depend on the
    /// calendar or on network / out-of-tree state must declare ``Hermeticity/temporal``
    /// or ``Hermeticity/external`` so the runner strips their gate authority — a
    /// finding the commit cannot be held responsible for must not block it.
    ///
    /// This is a protocol *requirement*, not merely an extension default: the runner
    /// holds checkers as `any QualityChecker`, and a witness supplied only by an
    /// extension would be dispatched statically to the default, silently disarming
    /// every declaration.
    var hermeticity: Hermeticity { get }

    /// The complete set of inputs whose change could change this checker's result, or
    /// `nil` (the default) to declare the checker **not cacheable** — it then runs every
    /// time.
    ///
    /// Returning a value opts the checker into incremental result caching. It **must**
    /// enumerate every input the checker reads (source files, config, etc.); bias to
    /// over-inclusion, because over-including only causes extra cache misses (slower),
    /// never a wrong reuse. Under-specifying an input is the *only* way caching could
    /// serve a stale pass. See ``CacheInputs`` and ``CheckerFingerprint``.
    func cacheInputs(configuration: Configuration) -> CacheInputs?
}

public extension QualityChecker {
    /// Default: checkers are parallel-safe unless they opt out.
    var isParallelSafe: Bool { true }

    /// Default: checkers are not cacheable (they run every time) until they opt in.
    func cacheInputs(configuration: Configuration) -> CacheInputs? { nil }
}
