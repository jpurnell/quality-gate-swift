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
| **Live** | A unit counts only if a current output file map names it and its source file exists — a deleted file's record stays on disk, and is not read. |
| **First-party** | Units whose source is under `/.build/` (dependency checkouts, generated sources) are skipped. Local path dependencies are first-party: their warnings count, as they do on a clean build. |
| **Current** | A record older than a source it was compiled from is not trusted. |
| **Success only** | Records are read only when `swift build` exited 0. After a failure the output has the errors and not every unit ran. |
| **Once** | A finding is keyed on path, line, column, severity and message. A warning printed by two compile jobs — emit-module and compile both report a declaration-level warning — is reported once. |

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

### What It Does Not See

- **Warnings with no source location** — linker warnings, plugin output, SwiftPM's own. They were never matched in the build's output either.
- **C-family compile units.** Output file maps list Swift sources; a warning in a `.c` or `.m` file is still reported only on the run that recompiles it. The coverage note counts Swift units and says so.
- **Other configurations and platforms.** Code under `#if os(iOS)`, or compiled only in release, is not built by this run and has no current record.
- **A target removed from `Package.swift` whose sources and build products remain.** Its map and records are still on disk, so its warnings are reported until the build directory is cleaned.

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
- ``BuildChecker/createResult(output:exitCode:duration:recorded:)``

### Recorded Diagnostics

- ``RecordedDiagnostics``
- ``CompileUnitIndex``
- ``CompileUnit``
- ``SerializedDiagnosticsReader``

### Configuration

- ``BuildChecker/buildArguments(for:)``
- ``BuildChecker/cacheInputs(configuration:)``
