# ``MemoryBuilder``

Generates project memory files from development-guidelines for AI context recovery.

## Overview

MemoryBuilder is a quality-gate checker that analyzes a Swift project's structure,
conventions, active work, architectural decisions, and environment, then writes
tagged Markdown files into the `.claude/memory/` directory. These files give AI
coding agents the context they need to resume work across sessions without
re-reading the entire codebase.

### Extractor Architecture

The pipeline is driven by the ``MemoryExtractor`` protocol. Each conforming type
reads one data source and returns zero or more ``MemoryEntry`` values:

| Extractor | Data source | Output file |
|---|---|---|
| ``ProjectProfileExtractor`` | `Package.swift` | `project_profile.md` |
| ``ArchitectureExtractor`` | `Package.swift` target graph | `project_architecture.md` |
| ``ActiveWorkExtractor`` | Git log, branch, checklists | `project_active_work.md` |
| ``EnvironmentExtractor`` | Swift toolchain, platform | `reference_environment.md` |
| ``ConventionExtractor`` | Project `CLAUDE.md` | `feedback_conventions.md` |
| ``ADRExtractor`` | `06_ARCHITECTURE_DECISIONS.md` | `project_decisions.md` |

The ``MemoryBuilder`` struct orchestrates the run: it instantiates every extractor,
collects their entries, delegates writing to ``MemoryWriter``, and finishes with a
validation pass from ``MemoryFileValidator``.

### Validation Pass

After all files are written, ``MemoryFileValidator`` performs two checks:

- **Index link validation** -- every `[Title](file.md)` link in `MEMORY.md` must
  resolve to an existing file in the memory directory.
- **Generated-file integrity** -- each file tagged with
  `generated-by: memory-builder` must contain valid YAML frontmatter and a
  non-empty body.

Validation diagnostics are appended to the same ``CheckResult`` returned by the
extraction phase, so a single quality-gate run surfaces both generation and
integrity issues.

### Configuration

MemoryBuilder accepts a `guidelinesPath` parameter (default `"development-guidelines"`)
that locates the development-guidelines directory relative to the project root. The
output directory is auto-detected from the `CLAUDE_PROJECT_DIR` environment variable
or derived from `~/.claude/projects/<mangled-path>/memory/`.

Manually-written memory files (those lacking the `generated-by: memory-builder`
frontmatter tag) are never overwritten. The `MEMORY.md` index merge preserves
manual lines and regenerates only the lines it owns.

### Out of Scope

- MemoryBuilder does not push memory files to a remote or synchronize across
  machines. It writes to the local Claude project directory only.
- It does not generate or modify `CLAUDE.md` itself; ``ConventionExtractor``
  reads that file but never writes back.
- Runtime telemetry, caching of extraction results, and incremental builds are
  not supported. Every run performs a full extraction.

## Topics

### Essentials

- ``MemoryBuilder``
- ``MemoryExtractor``
- ``MemoryEntry``

### Extractors

- ``ProjectProfileExtractor``
- ``ArchitectureExtractor``
- ``ActiveWorkExtractor``
- ``EnvironmentExtractor``
- ``ConventionExtractor``
- ``ADRExtractor``

### Writing and Indexing

- ``MemoryWriter``

### Validation

- ``MemoryFileValidator``

### Guides

- <doc:MemoryBuilderGuide>
