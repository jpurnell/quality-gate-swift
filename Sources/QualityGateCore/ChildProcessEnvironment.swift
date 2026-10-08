import Foundation

/// The environment a spawned build tool should run in: the gate's own, minus the
/// repository git scoped to whichever hook the gate is running inside.
///
/// git runs a hook with the repository it is operating on written into the environment.
/// Captured with `env | grep ^GIT_` (git 2.55.0, 2026-10-08):
///
/// | Hook | Ordinary clone | Linked worktree |
/// |---|---|---|
/// | `pre-commit` | `GIT_INDEX_FILE=.git/index`, `GIT_PREFIX`, `GIT_EXEC_PATH`, `GIT_EDITOR`, `GIT_AUTHOR_*` | the same, with `GIT_INDEX_FILE` absolute, **plus `GIT_DIR=<main>/.git/worktrees/<name>`** |
/// | `pre-push` | `GIT_PREFIX`, `GIT_EXEC_PATH`, `GIT_EDITOR` | the same, **plus `GIT_DIR`** |
///
/// Those variables are correct for the hook and wrong for anything the hook starts that
/// runs git for a *different* repository — which is what a build tool resolving package
/// dependencies does, once per dependency. Measured against `xcodebuild -list` and
/// `swift build` on a package with one unresolved dependency, adding one variable at a time:
///
/// - `GIT_DIR` — `Couldn’t check out revision ‘<sha>’` (`fatal: unable to read tree`). The
///   checkout ran against the hooked repository, which does not contain the dependency's
///   commit. This is why `xcode-build` failed in a worktree's pre-push hook on 2026-10-06
///   and passed by hand a minute later, and why it only showed in *linked worktrees*.
/// - `GIT_WORK_TREE` — `Failed to clone repository …: working tree '<project>' already exists`.
/// - `GIT_INDEX_FILE` (absolute) — **the tool exits 0** and the hooked repository's index is
///   left holding the dependency's file list (70 entries of `swift-numerics` where the
///   project's 6 had been; `git status` then fails with `unable to read <blob>`). The one
///   outcome here that is not a failure anyone sees.
/// - `GIT_PREFIX`, `GIT_EXEC_PATH`, `GIT_EDITOR` — no effect on either tool.
///
/// The failure needs *unresolved* packages, so it appears only in a fresh checkout — the
/// same shape as the `QG_NO_INDEX_BUILD` leak `TestRunner` documents — and one run by hand
/// "fixes" it, which is what made it look like a flake.
///
/// ## What is removed
///
/// ``repositoryScopedGitVariables``: the names that select a repository, its work tree, its
/// index or its object store, and so can only be right for the repository that set them.
///
/// ## What is kept
///
/// Everything else, including every other `GIT_*`. In particular the transport and
/// credential settings a private dependency is fetched with — `GIT_SSH_COMMAND`, `GIT_SSH`,
/// `GIT_ASKPASS`, `GIT_TERMINAL_PROMPT`, `GIT_SSL_*`, `GIT_HTTP_*` — and the configuration
/// channel: `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n`,
/// `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `GIT_CONFIG`. Stripping
/// the `GIT_` prefix wholesale would trade "could not check out revision" for "could not
/// authenticate" on exactly the machines — CI runners with a deploy key — least able to
/// say why.
///
/// `git rev-parse --local-env-vars` also lists `GIT_CONFIG`, `GIT_CONFIG_PARAMETERS` and
/// `GIT_CONFIG_COUNT`. They are deliberately **not** removed: they carry `git -c` and
/// injected configuration, which is how a user hands credentials or a URL rewrite to a
/// child on purpose, and none of them names a repository.
///
/// ## When not to use this
///
/// A checker that runs git *to read the audited repository* and passes that repository's
/// directory as the working directory is unaffected by this function either way: with the
/// scope removed, git discovers the repository from the directory it is run in, which is
/// the audited one.
public enum ChildProcessEnvironment {

    /// The git variables that name one particular repository, and why each is removed.
    ///
    /// - `GIT_DIR`: the repository itself. Set for every hook of a linked worktree.
    /// - `GIT_WORK_TREE`: its working tree. Set when git was invoked with `--work-tree` or
    ///   the repository configures `core.worktree`.
    /// - `GIT_INDEX_FILE`: its index — during a commit, possibly a temporary one. A child
    ///   that checks anything out writes another repository's entries into it.
    /// - `GIT_PREFIX`: the subdirectory git was invoked from, relative to that work tree.
    /// - `GIT_COMMON_DIR`: the main repository a linked worktree shares objects and refs with.
    /// - `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_QUARANTINE_PATH`:
    ///   its object store. Set together during `pre-receive` and `update`, where incoming
    ///   objects are quarantined; a child's objects would be written into the quarantine.
    /// - `GIT_IMPLICIT_WORK_TREE`, `GIT_GRAFT_FILE`, `GIT_SHALLOW_FILE`,
    ///   `GIT_NO_REPLACE_OBJECTS`, `GIT_REPLACE_REF_BASE`: the rest of what
    ///   `git rev-parse --local-env-vars` reports as local to one repository.
    /// - `GIT_EXEC_PATH`: not a repository, but scoped to the *git binary* that ran the
    ///   hook — it is that binary's own helper directory. A tool that runs a different git
    ///   (`xcodebuild` uses Xcode's; the hook here was run by Homebrew's) would otherwise
    ///   execute one version's helpers from another's front end. Every git finds its own
    ///   when the variable is absent.
    public static let repositoryScopedGitVariables: [String] = [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_PREFIX",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_QUARANTINE_PATH",
        "GIT_IMPLICIT_WORK_TREE",
        "GIT_GRAFT_FILE",
        "GIT_SHALLOW_FILE",
        "GIT_NO_REPLACE_OBJECTS",
        "GIT_REPLACE_REF_BASE",
        "GIT_EXEC_PATH",
    ]

    /// `parent` with ``repositoryScopedGitVariables`` removed and nothing else changed.
    ///
    /// A pure function, so that what a child receives can be tested without spawning one.
    ///
    /// - Parameter parent: The environment the child would otherwise inherit.
    /// - Returns: The environment to launch the child with.
    public static func withoutGitRepositoryScope(_ parent: [String: String]) -> [String: String] {
        var child = parent
        for name in repositoryScopedGitVariables {
            child.removeValue(forKey: name)
        }
        return child
    }

    /// This process's environment with git's repository scope removed — what to pass as
    /// `environment:` when launching `swift`, `xcodebuild` or any tool that may run git or a
    /// package manager on its own account.
    public static var forBuildTool: [String: String] {
        withoutGitRepositoryScope(ProcessInfo.processInfo.environment)
    }
}
