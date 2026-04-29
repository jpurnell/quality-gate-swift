# Understanding MemoryBuilder

Learn why MemoryBuilder exists, how its extraction pipeline works, and how to
configure it for your project.

## Why This Module Exists

AI coding agents lose all context between sessions. When an agent starts a new
conversation it has no memory of which branch was active, what architectural
decisions have been made, or which implementation checklist is in progress. Human
developers solve this by reading notes and commit history; MemoryBuilder
automates the equivalent for AI agents.

The module writes a set of small, focused Markdown files into the
`.claude/memory/` directory. Claude Code loads these files at session start,
giving the agent an immediate snapshot of the project without scanning every
source file.

## How Extractors Work

Every extractor conforms to the ``MemoryExtractor`` protocol. The protocol
requires a single async method that receives the project root, the
development-guidelines path, and the contents of the global `~/.claude/CLAUDE.md`
(used for deduplication). It returns zero or more ``MemoryEntry`` values.

### ProjectProfileExtractor

Parses `Package.swift` with regular expressions to extract the package name,
Swift tools version, targets, test targets, and external dependencies. Produces
`project_profile.md`.

### ArchitectureExtractor

Also reads `Package.swift`, but focuses on the internal dependency graph. For
each `.target`, `.executableTarget`, and `.testTarget` declaration it extracts
the `dependencies:` array and builds a module-level dependency map. Produces
`project_architecture.md`.

### ActiveWorkExtractor

Shells out to `git` to capture the current branch and the last ten commits. It
also scans the `04_IMPLEMENTATION_CHECKLISTS/` directory for any file whose name
begins with `CURRENT_`. Produces `project_active_work.md`.

### EnvironmentExtractor

Detects the host platform at compile time (`#if os(macOS)`) and runs
`swift --version` and `sysctl` to capture the local toolchain and hardware.
Produces `reference_environment.md`.

### ConventionExtractor

Reads the project-level `CLAUDE.md`, splits it into H2 sections, and filters out
any section whose heading already appears in the global `~/.claude/CLAUDE.md`.
The remaining project-specific sections become `feedback_conventions.md`. This
deduplication prevents the agent from seeing the same rule twice.

### ADRExtractor

Reads `06_ARCHITECTURE_DECISIONS.md` from the development-guidelines core rules
directory. It splits the file on `` ```yaml `` fenced blocks, parses each block
with the Yams YAML library, and keeps only entries whose status is `accepted` or
`amended`. Produces `project_decisions.md` with a counted summary and a pointer
to the full log.

## The Validation Pass

After every extractor has run and files have been written, ``MemoryFileValidator``
performs a post-write audit:

1. **Broken index links** -- It reads `MEMORY.md` line by line, extracts every
   Markdown link of the form `[Title](filename.md)`, and checks that the linked
   file exists on disk. Missing targets produce a warning diagnostic with the
   exact line number.

2. **Malformed generated files** -- It lists every `.md` file in the memory
   directory (except `MEMORY.md` itself), skips any that lack the
   `generated-by: memory-builder` frontmatter tag (those are manually written),
   and validates:
   - The file begins with `---` (YAML frontmatter present).
   - The body below the closing `---` is non-empty.

   Files that fail either check receive a warning with a suggested fix of
   `"Regenerate with --check memory-builder"`.

## How to Configure and Use

### Minimum Setup

MemoryBuilder runs as part of the quality-gate pipeline. If your project already
uses quality-gate-swift with a `development-guidelines/` directory at the project
root, no extra configuration is needed. The default `guidelinesPath` of
`"development-guidelines"` will be used automatically.

### Custom Guidelines Path

If your guidelines directory lives at a different relative path, pass it when
constructing the checker:

```swift
let builder = MemoryBuilder(guidelinesPath: "docs/guidelines")
```

### Output Directory Detection

MemoryBuilder resolves the output directory in two steps:

1. If the `CLAUDE_PROJECT_DIR` environment variable is set, it appends `/memory`
   to that path.
2. Otherwise it constructs `~/.claude/projects/-<mangled-project-root>/memory/`,
   where the mangled path replaces `/` with `-`.

### Preserving Manual Edits

Any memory file that does not contain the `generated-by: memory-builder`
frontmatter tag is treated as manually written and will never be overwritten. The
`MEMORY.md` index merge also preserves manual lines: only lines containing the
`<!-- generated -->` HTML comment are replaced on each run.

### Running

Invoke the checker through the quality-gate CLI:

```bash
quality-gate --check memory-builder
```

The result includes a note-level diagnostic for every file written or skipped,
plus warning-level diagnostics from the validation pass if any issues are found.
