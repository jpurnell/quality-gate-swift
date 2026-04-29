# LoggingAuditor Guide

A practical walkthrough of every LoggingAuditor rule, with the bug it catches and the recommended fix.

## Why this auditor exists

Two patterns silently degrade production observability:

1. **`print()` in production code.** `print()` writes to stdout, which is invisible in most deployment contexts (iOS devices, background daemons, server containers). Crashes, slowdowns, and logic errors go unrecorded. `os.Logger` writes to the unified logging system, supports levels, is filterable in Console.app, and survives process termination.

2. **Silent error swallowing via `try?`.** `try?` discards the error entirely. When a network call, file write, or decoding operation fails, the failure is invisible unless the developer explicitly logs it nearby. In practice, `try?` without adjacent logging is a silent data-loss vector.

LoggingAuditor catches both shapes plus the transitional smell of using `print()`/`NSLog()` without even importing `os`.

## Rule walkthrough

### `logging.print-statement`

**Severity:** error

`print()` and `debugPrint()` are development conveniences that have no place in shipped application code. They cannot be filtered by log level, they do not appear in Console.app on-device, and they incur string interpolation cost even when nobody is reading the output.

```swift
// flagged
func fetchUser() async throws -> User {
    let data = try await URLSession.shared.data(from: url).0
    let user = try JSONDecoder().decode(User.self, from: data)
    print("Fetched user: \(user.name)")  // logging.print-statement (error)
    return user
}
```

```swift
// accepted
import os

private let logger = Logger(subsystem: "com.app", category: "Network")

func fetchUser() async throws -> User {
    let data = try await URLSession.shared.data(from: url).0
    let user = try JSONDecoder().decode(User.self, from: data)
    logger.info("Fetched user: \(user.name, privacy: .public)")
    return user
}
```

Both `print()` and `debugPrint()` are flagged. `NSLog()` is tracked but not flagged as an error -- it only contributes to the `no-os-logger-import` rule.

### `logging.silent-try`

**Severity:** warning

`try?` converts a throwing call into an optional, discarding the error. This is appropriate in fire-and-forget contexts but dangerous when the discarded error represents a user-visible failure.

```swift
// flagged
func saveSettings(_ settings: Settings) {
    let data = try? JSONEncoder().encode(settings)
    // logging.silent-try (warning)
    // The encode failure is invisible -- corrupt settings? schema mismatch?
    if let data {
        try? data.write(to: settingsURL)
        // logging.silent-try (warning)
    }
}
```

The auditor checks three escape hatches before flagging:

1. **Allowed function names.** If the `try?` expression contains a string from `allowedSilentTryFunctions` (default: `Task.sleep`, `JSONEncoder`, `JSONDecoder`), the rule does not fire. Note: `JSONEncoder` and `JSONDecoder` are in the default allow-list, so the example above would actually pass for the encode call. Customize this list to match your project's fire-and-forget patterns.

2. **Adjacent logging.** If any line within two lines above or below the `try?` contains a recognized logger name (`Logger`, `logger`, `log`, `NSLog`, or any `customLoggerNames`) or a structured logging method (`.error(`, `.warning(`, `.info(`, `.notice(`, `.debug(`, `.fault(`), the rule does not fire.

3. **Suppression comment.** A `// silent:` comment (or your configured `silentTryKeyword`) on the same line or the line immediately above suppresses the warning and records a `DiagnosticOverride`.

```swift
// accepted -- adjacent logging
func saveSettings(_ settings: Settings) {
    do {
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsURL)
    } catch {
        logger.error("Failed to save settings: \(error)")
    }
}
```

```swift
// accepted -- suppression comment with reason
// silent: best-effort cache write; failure is non-critical
try? cache.write(data, forKey: key)
```

```swift
// accepted -- adjacent logging within 2-line window
try? fileManager.removeItem(at: tempURL)
logger.debug("Cleaned up temp file at \(tempURL.path)")
```

```swift
// accepted -- allowed function name (fire-and-forget sleep)
try? await Task.sleep(nanoseconds: 500_000_000)
```

### `logging.no-os-logger-import`

**Severity:** warning

This rule fires at the end of a file if the file contains any `print()`, `debugPrint()`, or `NSLog()` call but does not have `import os` or `import OSLog`. It is a transitional nudge: if you are already calling console output functions, you should at least have `os` imported so you can migrate incrementally.

```swift
// flagged -- uses print() but no import os
import Foundation

func start() {
    print("Starting up")  // logging.no-os-logger-import (warning) on line 1
}
```

```swift
// accepted -- import os is present
import Foundation
import os

func start() {
    print("Starting up")  // still flagged by print-statement rule,
                           // but no-os-logger-import does NOT fire
}
```

Note that `logging.print-statement` and `logging.no-os-logger-import` can fire on the same file. The print-statement rule flags each call site; the no-os-logger-import rule fires once at the top of the file. Fixing the print-statement violations (by migrating to `os.Logger`) resolves both.

## False positives and suppression

The auditor is intentionally conservative. Here are the known edge cases and how to handle them:

### `print()` in CLI tools

Command-line tools legitimately use `print()` for user-facing output. If your project is a CLI, set `projectType: "library"` in `.quality-gate.yml` to skip the auditor entirely, or add `// logging:` comments on intentional stdout output.

```swift
// logging: CLI user-facing output
print("Processing \(files.count) files...")
```

### `try?` with error handling elsewhere

Sometimes the error is handled by a caller or by a different code path. If the adjacent-logging window (two lines) does not catch it, add a suppression comment:

```swift
// silent: caller retries on nil return
let result = try? attempt()
```

### Custom logger wrappers

If your project uses a logging wrapper (e.g., `AppLogger.shared.info(...)`) that the auditor does not recognize, add the wrapper name to `customLoggerNames`:

```yaml
logging:
  customLoggerNames: ["AppLogger", "Analytics"]
```

This ensures the adjacent-logging check for `logging.silent-try` recognizes your wrapper within the two-line window.

### `NSLog` is not flagged as an error

`NSLog()` is tracked for the `no-os-logger-import` rule but is not flagged as an error by `logging.print-statement`. This is intentional: `NSLog` does write to the system log (unlike `print`), so it is a lesser concern. Migration to `os.Logger` is still recommended for performance and privacy reasons, but the auditor does not block on it.

If you find yourself suppressing the same rule across many files, the auditor may not be well-calibrated for your project. Consider adjusting `projectType`, `allowedSilentTryFunctions`, or `customLoggerNames` before reaching for per-line suppression.
