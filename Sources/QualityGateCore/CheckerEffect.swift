import Foundation

/// What a checker leaves behind.
///
/// ## Why this is separate from ``CheckerKind``
///
/// A checker can be perfectly code-shaped and still write something. Kind answers *what it
/// judges*; this answers *what it costs to run somewhere you do not own*. A survey profile
/// needs both, and inferring the second from the first is exactly the assumption that would
/// eventually be wrong.
///
/// ## Why three cases rather than a Bool
///
/// Found by running the gate against an unfamiliar repository on 2026-08-16. `memory-builder`
/// was observed writing files, and the first conclusion — that it had modified the cloned
/// repository — was wrong: it writes to `~/.claude/projects/<mangled-path>/memory/`, outside
/// the tree entirely. The clone was never touched.
///
/// Those are very different severities. Litter in the operator's home directory is untidy;
/// modifying a repository under test is a different kind of wrong, and a Bool flattens them
/// into the same answer. Keeping them apart also means the declaration says *where*, so the
/// next reader does not have to trace the write path to find out — which is the work that
/// produced the mistaken conclusion above.
///
/// ## No default, deliberately
///
/// A checker that writes and forgets to say so is precisely the failure this exists to
/// prevent, and a default of ``readOnly`` is exactly what such a checker would inherit. The
/// cost is 48 declarations of `.readOnly`; the alternative is one silent writer in a survey of
/// thirty strangers' repositories.
public enum CheckerEffect: String, Sendable, Codable, CaseIterable, Equatable {

    /// Reads and reports. Leaves no artifact a reader would not expect from compiling.
    ///
    /// The overwhelming majority, and the only effect safe to point at a repository nobody
    /// here owns.
    ///
    /// **Compilation output is not a write.** `build`, `test`, and every index-backed checker
    /// produce `.build/` in the project directory, and treating that as mutation would make
    /// this property vacuous — nearly everything would declare it, and the one checker that
    /// really does write would be indistinguishable from the crowd. `.build/` is gitignored,
    /// reproducible, and the unavoidable cost of analysing Swift at all. What this property is
    /// for is the write a reader would *not* predict from "it analysed my code".
    case readOnly = "read-only"

    /// Writes outside the project under test — caches, generated memory, reports.
    ///
    /// `memory-builder` writes a memory directory keyed on the project's absolute path, so a
    /// survey of thirty repositories leaves thirty of them, and re-cloning to a different path
    /// makes new ones rather than reusing the old. Untidy rather than dangerous, and excluded
    /// from survey profiles on that basis.
    case writesOutsideTree = "writes-outside-tree"

    /// Modifies the project under test — files a reader would notice, not build output.
    ///
    /// Nothing currently registered does this, and ``CheckerSelection`` says so in prose:
    /// "run all checks" is non-destructive because nothing registered can mutate the tree.
    /// This case exists so that claim is a declared property something can assert on, rather
    /// than a sentence that goes stale the first time it stops being true.
    ///
    /// A checker declaring this must never appear in a profile aimed at a repository the
    /// operator does not own, and arguably should not run without an explicit flag at all —
    /// which is why cleanup became the `quality-gate clean` subcommand rather than a checker.
    case writesTree = "writes-tree"
}
