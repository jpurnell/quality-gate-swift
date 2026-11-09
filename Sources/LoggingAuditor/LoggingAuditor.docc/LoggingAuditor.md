# ``LoggingAuditor``

Enforces logging hygiene in application projects by catching `print()` in production code, silent `try?` without error logging, and missing `os` imports.

## Overview

LoggingAuditor uses SwiftSyntax to walk Swift source files under `Sources/` and apply three rules that promote structured logging over ad-hoc console output. It tracks `import os` declarations, `print()`/`NSLog()` calls, and `try?` expressions to produce actionable diagnostics.

This auditor is **gated by project type**. When `projectType` is set to `"library"`, the auditor returns `.skipped` immediately -- libraries intentionally omit logging, and consumers decide what to log. Only `"application"` projects are checked.

Test files (paths containing `Tests`) and paths matching `excludePatterns` in the gate-wide configuration are automatically skipped.

### Detected rules

| Rule ID | Severity | What it catches |
|---------|----------|-----------------|
| `logging.print-statement` | error | `print()` or `debugPrint()` calls in production code |
| `logging.silent-try` | warning | `try?` without adjacent error logging or suppression comment |
| `logging.no-os-logger-import` | warning | File uses `print()`/`NSLog()` but does not `import os` |
| `logging.catch-without-logging` | warning | A `catch` whose error disappears: not logged, not rethrown, not handed on |
| `logging.no-metrickit-subscriber` | note (configurable) | An app target that never subscribes to MetricKit (project-level, see below) |
| `logging.metrickit-payload-ignored` | note (configurable) | A MetricKit subscriber that lacks a payload handler or only logs what it receives |

### MetricKit: an app reads its own crash and exit reports

An app that does not subscribe to `MXMetricManager` gets no crash, hang or exit-reason data
from users except through Apple's web tools. These two rules are about an app target taken as
a whole, so they run once per app target after the per-file pass (see `DiagnosticsAndFeedback.md`
in KEXPPower for the client work they check).

**Opt-in, and advisory.** The rules are evaluated only for a project whose own
`.quality-gate.yml` declares how it is distributed:

```yaml
logging:
  distribution: [testFlight, appStore, developerID]
  metricKitSeverity: note   # note (default) | warning | error
```

`distribution` is a declared fact about the project (somebody other than its author receives its
payloads), not an exclusion: a project that declares none is not evaluated, with no findings and no
noise. Unknown values are a configuration error. Findings are **notes** by default, so they do not
break the zero-warnings rule; `metricKitSeverity` raises them to `warning` or `error`, and making
the rules errors later is a change of that default.

**Which targets.** Only app targets, judged one at a time on their own sources. A target is an
app when its sources contain an entry point: an `@main` type conforming to `App`, a class
conforming to `UIApplicationDelegate`, `NSApplicationDelegate`, `WKApplicationDelegate` or
`WKExtensionDelegate`, or `@UIApplicationMain`/`@NSApplicationMain`. `library` and `cli`
projects are skipped. In an Xcode project the target list comes from the `.xcodeproj`:
`PBXNativeTarget`s whose `productType` begins `com.apple.product-type.application` (so
extensions and test bundles are not apps), their sources from the Sources build phase and
synchronized folders, their platform from `SDKROOT`/`SUPPORTED_PLATFORMS`. When a readable
`.xcodeproj` exists it is authoritative; otherwise each `Sources/<Name>/` is a target.

**`logging.no-metrickit-subscriber`** is satisfied when the target has a type conforming to
`MXMetricManagerSubscriber` and a call to `MXMetricManager.shared.add(_:)` reachable from app
start: an `App` initializer, `application(_:didFinishLaunchingWithOptions:)`,
`applicationDidFinishLaunching`, or something one call level below those (a function they call
by name, or the initializer of a type they mention). Deeper indirection is not followed; call the
registration plainly from `init`. Code in the `#else` of `#if canImport(MetricKit)` is not
counted; code outside any `#if` is accepted.

**`logging.metrickit-payload-ignored`** applies to each accepted subscriber. It must have both
`didReceive(_: [MXMetricPayload])` and `didReceive(_: [MXDiagnosticPayload])`, and each body must
do more than log: a call that is not `print`/`Logger`, or an assignment, counts as handing the
payload on. The check is syntactic; it cannot tell that what receives the payload is correct.

**No suppression.** The `// logging:` comment does not silence either rule, and
`requireMetricKitSubscriber` cannot be turned off. The structural exemptions are: the project type, and `metricKitUnsupportedPlatforms` (an app target is exempt
when every platform it builds for is listed) and `metricKitNoDiagnosticPlatforms` (the diagnostic
handler is not required). Both lists are empty by default because which platforms lack MetricKit
has not been verified; add a platform only after checking it.

### What a `catch` may do with its error

`logging.catch-without-logging` is about an error that vanishes. A `catch` is accepted when
its body does any one of these:

- **throws** — the error, or another in its place;
- **logs** — a call on a logger (`logger.error(…)`, `Self.fixLogger.warning(…)`), `NSLog` or
  `os_log`;
- **translates** the error into a configured domain value on every exit
  (`logging.errorValueTypes`);
- **surfaces** the caught error, which is decided by following the error's own name:
  - it is written to stderr — `FileHandle.standardError.write(Data("…\(error)".utf8))`,
    `fputs("…\(error)", stderr)`, `print(error, to: &standardError)`;
  - it is passed to a call and the body's last statement does not return —
    `print("failed: \(error)")` then `exit(1)`, or `fatalError("\(error)")`;
  - every exit from the body returns a value that mentions it —
    `return "Invalid pattern: \(error.localizedDescription)"`, `return .failure(error)`.

The name followed is the one the clause binds: the implicit `error`, or `failure` in
`catch let failure as DecodingError`. `catch is CancellationError` binds nothing, so nothing in
its body counts. A case or method merely *called* `error` — `.error(.value)` — is not the
caught error.

Still reported, on purpose: `catch { exit(1) }`, which ends the process without saying why; a
fixed string written to stderr; the error printed to stdout by code that then carries on; a
body where one exit of several returns a value without the error, falls off the end, or leaves
by `break` or `continue`; and an error copied into a local before being written out, which is
not followed.

### Configuration

LoggingAuditor is configured via `LoggingAuditorConfig` in `.quality-gate.yml`:

```yaml
logging:
  projectType: application
  silentTryKeyword: "silent:"
  allowedSilentTryFunctions: ["Task.sleep", "JSONEncoder", "JSONDecoder"]
  customLoggerNames: ["HarborLog", "WatchLog"]
```

**`projectType`** (`String`, default: `"application"`) -- `"application"` enables every rule. `"cli"` skips `logging.print-statement` and `logging.no-os-logger-import`, because a command-line tool's output *is* `print()`; the other rules still run. `"library"` skips the auditor entirely. Any other value is treated as `"library"` and the auditor reports `skipped`. A `cli` or `library` setting is listed under *Exclusions in force* in the run summary.

**`silentTryKeyword`** (`String`, default: `"silent:"`) -- The comment keyword that suppresses `logging.silent-try` warnings. The comment must appear on the same line as the `try?` expression or on the immediately preceding line.

**`allowedSilentTryFunctions`** (`[String]`, default: `["Task.sleep", "JSONEncoder", "JSONDecoder"]`) -- Function names where `try?` is considered safe fire-and-forget usage. If the `try?` expression text contains any of these strings, the silent-try rule is not applied.

**`customLoggerNames`** (`[String]`, default: `[]`) -- Additional logger type or instance names beyond the built-in set (`Logger`, `logger`, `log`, `NSLog`). When a custom name appears within two lines of a `try?` expression, the adjacent-logging check passes. Useful for project-specific logging wrappers.

### Suppression comments

Each rule has its own suppression mechanism:

- **`logging.print-statement`**, **`logging.missing-privacy`**, **`logging.bare-logger-init`**, **`logging.catch-without-logging`**, **`logging.no-os-logger-import`**: Add `// logging: <reason>` on the same line or the line above (line 1 of the file for `no-os-logger-import`).
- **`logging.silent-try`**: Add `// silent: <reason>` (or your configured `silentTryKeyword`) on the same line or the line above.

Both markers record an override for every finding they silence — and only for a finding
they silence: a marker beside a `try?` that is on the allow-list, or beside a logger call
that is already annotated, records nothing. Neither marker's reason is enforced, so it is
judged when the run is reported: eight words or more, not a stock phrase and not repeated in
the file is an **acknowledgement**; anything less is a **suppression**. See *Acknowledgements
are not suppressions* in `GUIDE.md`.

(Between June and October 2026 these two markers silenced without recording anything, while
this page said they recorded a `DiagnosticOverride`.)

The comment must be a line comment (`//`), not a block comment. Blank lines between the comment and the flagged expression break adjacency.

### Out of scope

- Cross-module logging analysis (would require IndexStore)
- Detecting misuse of `os.Logger` subsystem/category naming
- Flagging `NSLog` as an error (it is only tracked for the `no-os-logger-import` rule)
- Following a caught error through a local variable or into a closure
  (`logging.catch-without-logging` reads the body's own statements)

## Topics

### Essentials

- ``LoggingAuditor/check(configuration:)``
- ``LoggingAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:LoggingAuditorGuide>
