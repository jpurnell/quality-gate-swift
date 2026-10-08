# ``BuildChecker``

Executes `swift build` and reports every compiler diagnostic the current sources produce — whether or not this run compiled the file that carries it.

## Overview

BuildChecker runs the Swift compiler and extracts errors, warnings, and notes from its output. This enables CI pipelines and quality gates to programmatically check for build issues.

### How It Works

1. Executes `swift build` with the configured options
2. Captures both stdout and stderr (Swift outputs diagnostics to stderr)
3. Parses the output using regex to extract structured diagnostics
4. If the build succeeded, reads the diagnostics the compiler *recorded* for every first-party compile unit, and merges them with what was printed
5. Returns a `CheckResult` with pass/fail status and detailed diagnostics

### Diagnostic Format

BuildChecker parses the standard Swift compiler output format:

```
/path/to/File.swift:42:15: error: cannot find 'foo' in scope
    let x = foo
            ^~~
```

Each diagnostic includes:
- **File path** - Full path to the source file
- **Line and column** - Exact location of the issue
- **Severity** - error, warning, or note
- **Message** - The compiler's description of the issue, as text: colour and hyperlink escapes are removed, so a diagnostic group reads `[#NoUsage]`

### A Warm Build Keeps Its Warnings

SwiftPM compiles only what is out of date, and the compiler prints a diagnostic only while compiling. Reading the build's output alone, the checker's findings were the warnings of the files *this invocation happened to rebuild*: a clean build directory reported a warning, the next run on the same tree reported none and passed, and touching the file brought it back.

The compiler already writes each compile job's diagnostics down. The build system hands the Swift driver an output file map naming a serialized-diagnostics (`.dia`) file per job; the file is rewritten when the job runs and left alone when it does not. After a successful build, ``RecordedDiagnostics`` reads those records under these rules:

| Rule | Statement |
|---|---|
| **Live** | A unit counts only if an output file map names it and its source file exists — a deleted file's record stays on disk, and is not read. |
| **Of this build** | A unit counts only if the build that just ran names its output file map. A renamed target, or a variant directory an older toolchain named differently, leaves a map and records nothing will refresh; they are neither read nor reported as unread. |
| **First-party** | Units whose source is a dependency's or the build directory's — under `/.build/` — are skipped, by the same rule that scopes a printed diagnostic (see below). Local path dependencies are first-party: their warnings count, as they do on a clean build. |
| **Current** | A record older than a source it was compiled from is not trusted. |
| **Not stale** | A diagnostic is evidence about the file it points at *as it was when the record holding it was written*. One that points at a file modified since is discarded, with its notes. |
| **Success only** | Records are read only when `swift build` exited 0. After a failure the output has the errors and not every unit ran. |
| **Once** | A finding is keyed on path, line, column, severity and message. A warning printed by two compile jobs — emit-module and compile both report a declaration-level warning — is reported once. |

### A Record Is Not Only About Its Own Source

The compiler writes a diagnostic about `F.swift` into other units' records too. Every primary file of a compile batch that contains a macro expansion receives the batch's diagnostics, so a warning in one Swift Testing file is also in the records of the four or five files compiled beside it. Edit `F.swift` and only its own unit is recompiled: its record is rewritten, the siblings' are not, and they go on describing `F` as it was — at lines that have moved, or code that is gone. Each of those records is *current*, because it is no older than its own source.

So the **Not stale** rule compares each diagnostic with the file it points at:

- A diagnostic whose file was modified after the record holding it was written is discarded, and its notes go with it. The file's own unit, compiled after the edit, is the authority for the file: a warning that is still there is in that record, at its present line, and is reported once.
- A warning inside a macro expansion is located in a generated buffer (`…/swift-generated-sources/@__swiftmacro_…swift`) that the compiler writes once and does not touch when the expansion site is fixed. It is judged by the file its *in expansion of macro … here* note names.
- A diagnostic about a file that has not changed is kept, whichever record holds it — a header with no unit of its own, or a file whose own unit was recompiled because something it depends on changed. The comparison is with the file's modification date, not with its own record's: being recompiled is not being edited.
- A warning in `G.swift` keeps its notes even when one points into a file edited since. It is the compiler's verdict on `G`, and stands while `G`'s unit is current.

Whatever is discarded is counted in the coverage note, once each however many records held it.

### The Build That Just Ran

A build directory outlives the builds that wrote it. An output file map on disk says a target *was* built here, not that it still is. Which maps belong to the current build is something the build system writes down, and the checker reads it rather than asking SwiftPM again:

| Build system | Description | 
|---|---|
| swiftbuild | `.build/out/Intermediates.noindex/XCBuildData/<id>.xcbuilddata/manifest.json`, `<id>` being the last line of `prior-build-descriptions.txt` |
| native | `.build/<configuration>.yaml` |

`.build/.buildSystem_<configuration>` says which of the two built last. A map the description does not name is an orphan. That includes a target this invocation simply did not build — the test targets, when `build.includeTests` is `false`: their records were written by some other build, and this one does not vouch for them. Nothing is called an orphan on a guess: when no description is found, or the one found names none of the configuration's maps, every map is treated as live, exactly as before.

### A Dependency's Warnings Are Not Counted

A warning or note in a dependency checkout or in the build directory is not this package's and does not count against it; an error always does, so a dependency that fails to compile fails the build. The rule is `DependencyOrigin` in `QualityGateCore`, shared with `doc-lint` and `xcode-build`, and the README's *Whose warning is it* states it once for all three.

The verdict is reached after that scoping, never before: a build whose only warnings are a dependency's is `passed`. What was scoped out is counted in a note, `gate.dependency-diagnostics-not-counted`:

```
20 warnings in dependency mlx-swift were not counted; they are not this package's source
```

### When the Checker Cannot Vouch for a Pass

If any live first-party unit has no readable, current record — or no output file map is found at all, as with an unknown build layout — the result carries `build.warnings-unverified` and its status is a warning:

```
2 of 9 compile units were up to date and their recorded diagnostics could not be read
(first: `Sources/X/Y.swift`). Warnings in those files, if any, are not in this report.
A clean build (`rm -rf .build`) reports them.
```

Every successful result also carries the note `build.diagnostic-coverage`, the one line that distinguishes "clean" from "not looked at":

```
9 Swift compile unit(s): 1 compiled by this run, 8 read from recorded diagnostics.
```

It also says what was looked at and set aside:

```
63 Swift compile unit(s): 2 compiled by this run, 61 read from recorded diagnostics.
4 recorded diagnostic(s) discarded as stale: the file each points at changed after the
record holding it was written. 3 compile unit(s) in 1 output file map(s) ignored as
orphaned: the build that just ran does not name them.
```

### What It Does Not See

- **Warnings with no source location** — linker warnings, plugin output, SwiftPM's own. They were never matched in the build's output either.
- **C-family compile units.** Output file maps list Swift sources; a warning in a `.c` or `.m` file is still reported only on the run that recompiles it. The coverage note counts Swift units and says so.
- **Other configurations and platforms.** Code under `#if os(iOS)`, or compiled only in release, is not built by this run and has no current record.
- **A cross-file diagnostic about a file edited since.** Some diagnostics about `F.swift` are produced only while compiling `G.swift`. If `F` is then edited in a way that does not make the build recompile `G`, `G`'s record is older than `F` and what it says about `F` is discarded — even if it is still true. It returns when `G` is next compiled. The alternative was reporting diagnostics at lines that no longer hold the code, which is what this rule replaced; the coverage note counts what was discarded so the trade is visible.
- **An edit that keeps an older modification date.** Staleness is a comparison of dates. A tool that restores a file's contents together with an earlier date (`cp -p`, `rsync -t`, an archive extraction) leaves a sibling's record looking newer than the file, and its diagnostics about that file are reported.
- **A macro-expansion diagnostic with no note on disk.** With nothing to compare its record against, it is kept.
- **Orphans, when the build left no description.** Telling a live unit from an orphan depends on the build description. Without one — an unknown layout, a future toolchain that moves it — every map is live again, and a stale variant directory can raise `build.warnings-unverified` as it used to. The description's format is not a documented interface; the scan asks only that it contain each map's absolute path as a quoted string.
- **C-family and other diagnostics in an orphaned directory** are as unseen as they were in a live one.

### No Result Cache

``BuildChecker/cacheInputs(configuration:)`` returns `nil`: a `build` verdict is never replayed from the gate's result cache. The build system is already a cache, a precise one, and a copy in front of it was keyed on less than the build system keys on — it omitted the build directory and local path dependencies, and was wrong in both directions because of it. A no-op build costs a few seconds, and with the recorded diagnostics read after it, it is a complete answer.

### Configuration

Configure via `.quality-gate.yml`:

```yaml
buildConfiguration: release  # or debug (default)
```

The records read are those of the configuration that was built.

### The Reader

The `.dia` container is the LLVM bitstream format Clang and Swift share. The reader is `TSCUtility.SerializedDiagnostics` from [swift-tools-support-core](https://github.com/swiftlang/swift-tools-support-core) (Apache-2.0), vendored under `Sources/BuildChecker/SerializedDiagnostics/` with its provenance and modifications in each file's header. The vendored copy throws where upstream traps: it reads whatever is on disk, and a truncated or overwritten record must surface as `build.warnings-unverified`, not as a crash.

## Topics

### Essentials

- ``BuildChecker/check(configuration:)``
- ``BuildChecker/parseBuildOutput(_:)``
- ``BuildChecker/createResult(output:exitCode:duration:recorded:projectRoot:)``

### Recorded Diagnostics

- ``RecordedDiagnostics``
- ``CompileUnitIndex``
- ``CompileUnit``
- ``RecordedDiagnostics/Coverage``
- ``SerializedDiagnosticsReader``

### Configuration

- ``BuildChecker/buildArguments(for:)``
- ``BuildChecker/cacheInputs(configuration:)``
