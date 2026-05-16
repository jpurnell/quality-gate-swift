# Design Proposal: Process Safety Auditor

**Date:** 2026-05-15
**Status:** Proposed
**Author:** Claude (AI Assistant)

---

## Problem Statement

Foundation's `Process` + `Pipe` pattern has a well-known deadlock: calling `waitUntilExit()` before reading pipe data via `readDataToEndOfFile()`. When child process output exceeds the ~64 KB pipe buffer, the process blocks on write, `waitUntilExit()` never returns, and the program hangs.

This bug existed across 13 call sites in quality-gate-swift and caused intermittent hangs during `--check build` and `--check unreachable` runs. It "works on retry" because cached builds produce less output.

### Root Cause

```swift
// DEADLOCK: process can't exit if pipe buffer is full
process.run()
process.waitUntilExit()                              // blocks forever
let data = pipe.fileHandleForReading.readDataToEndOfFile()  // never reached
```

### Correct Pattern

```swift
// SAFE: drain pipe first, then wait
process.run()
let data = pipe.fileHandleForReading.readDataToEndOfFile()  // drains as data arrives
process.waitUntilExit()                              // process already exited
```

---

## Proposed Solution

### Part 1: ProcessRunner Utility (QualityGateCore)

A shared `ProcessRunner` enum in QualityGateCore that encapsulates correct process execution:

```swift
public enum ProcessRunner: Sendable {
    public struct Output: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
    }

    public static func run(
        _ executablePath: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        mergeStderr: Bool = false
    ) throws -> Output
}
```

**Design decisions:**
- Enum (no instances) — this is a namespace for static functions
- Reads stdout/stderr before `waitUntilExit()` to prevent deadlock
- `mergeStderr` option for cases where stdout+stderr should combine
- Returns structured `Output` with exit code for consistent error handling
- `Sendable` for use in async contexts

### Part 2: ProcessSafetyAuditor (New Checker Module)

An AST-based auditor that detects the deadlock pattern at build time:

**Rule: `process.wait-before-read`**
- Severity: warning
- Trigger: `waitUntilExit()` called before `readDataToEndOfFile()` in the same scope
- Suggested fix: "Read pipe data before calling waitUntilExit(), or use ProcessRunner.run()"
- Disable comment: `// process-safety:disable`

**Detection strategy:**
1. Visit function/closure/accessor bodies
2. Collect all `.waitUntilExit()` and `.readDataToEndOfFile()` calls with line numbers
3. For each `waitUntilExit()`, check if any `readDataToEndOfFile()` occurs on a later line without any on an earlier line
4. Flag as warning if deadlock pattern detected

**Scope:** Scans `Sources/` directory only (same as other auditors).

**Edge cases handled:**
- Multiple pipes (stdout + stderr) — still flags if wait comes before either read
- No pipe reading at all — passes (no deadlock risk)
- No waitUntilExit — passes
- Disable comment on same line — suppresses

### Part 3: Migration of Existing Call Sites

All 13 existing `Process()` call sites migrated to either:
1. `ProcessRunner.run()` (preferred)
2. Inline fix: swap read/wait order (for cases with special handling)

**Files affected:**
| File | Call Sites | Approach |
|------|-----------|----------|
| BuildChecker.swift | 1 | ProcessRunner |
| IndexStoreManager.swift | 3 | ProcessRunner |
| UnreachableCodeAuditor.swift | 2 | ProcessRunner |
| DocLinter.swift | 1 | ProcessRunner |
| TestRunner.swift | 1 | ProcessRunner |
| DiskCleaner.swift | 1 | ProcessRunner |
| SwiftVersionChecker.swift | 1 | ProcessRunner |
| ActiveWorkExtractor.swift | 1 | ProcessRunner |
| EnvironmentExtractor.swift | 1 | ProcessRunner |
| ReleaseReadinessAuditor.swift | 1 | ProcessRunner |

---

## Constraints & Compliance

- **Concurrency:** `ProcessSafetyAuditor` is `Sendable` (stateless struct). `ProcessSafetyVisitor` is a `final class` (SyntaxVisitor requirement) used locally within `check()`.
- **Safety:** No force unwraps. Visitor uses guard-let for all optional access.
- **Determinism:** Pure AST analysis — no network, no randomness, no file system state dependency.
- **Performance:** Single-pass SyntaxVisitor. No process spawning. Expected <0.5s for quality-gate-swift's Sources/.
- **MCP:** Not applicable — this is an internal build-time auditor, not a user-facing API.

## Documentation Strategy

- **Type:** API Docs Only (no narrative article needed)
- Combines fewer than 3 APIs: `ProcessSafetyAuditor.check()` and `ProcessSafetyAuditor.auditSource()`
- Does not require theory/background — the deadlock pattern is self-explanatory
- DocC comments on public types and methods are sufficient

---

## Integration

### Package.swift Changes
- New library: `ProcessSafetyAuditor` with SwiftSyntax dependencies
- New test target: `ProcessSafetyAuditorTests`
- Added to `QualityGateCLI` dependencies

### CLI Registration
- Registered in checker array as `ProcessSafetyAuditor()`
- ID: `process-safety`
- Included in `--check all` runs

### Pre-commit Hook
- Included in fast AST checks (no process spawning needed)
- Added to the check classification table in 12_ENFORCEMENT.md

---

## Testing Plan

### Unit Tests (ProcessSafetyAuditorTests)
1. Detects `waitUntilExit()` before `readDataToEndOfFile()` — basic case
2. Passes when read comes before wait — correct order
3. Detects with two separate pipes (stdout + stderr)
4. Passes when no pipe reading occurs
5. Passes when no `waitUntilExit()` occurs
6. Respects `// process-safety:disable` comment
7. Detects pattern inside closures
8. Empty source produces no diagnostics

### Integration Test
- Run `quality-gate --check process-safety` against quality-gate-swift itself
- After migration: 0 warnings (all call sites use ProcessRunner)
- Before migration: would have caught all 13 deadlock sites

---

## Adversarial Review

### False Positives — What legitimate code would this flag incorrectly?

1. **Intentionally small output.** `xcrun --find swift` returns one line — no deadlock risk, but the pattern still matches. The `// process-safety:disable` escape hatch handles this, but it adds noise to safe code.

2. **Output discarded to /dev/null.** If `standardOutput` is set to `FileHandle.nullDevice` instead of a `Pipe`, there's no pipe to deadlock. The auditor doesn't track what `standardOutput` is assigned to — it only looks for `waitUntilExit()` vs `readDataToEndOfFile()` ordering. This means a process with null output + a pipe on stderr only could still get flagged when the pattern is actually safe for stdout.

3. **Pipe read in a different scope.** If `readDataToEndOfFile()` is called inside a closure dispatched on another queue (concurrent draining), the auditor would still flag it because it only looks at line ordering within the enclosing scope, not cross-thread data flow.

**Mitigation:** These are acceptable false positives. The deadlock pattern is dangerous enough that flagging borderline cases with a warning (not error) is the right tradeoff. The disable comment provides a clean escape. The false positive rate is low because `Process()` usage is rare in application code — it's primarily in tool/CLI code where output volume is unpredictable.

### False Negatives — What deadlock patterns would this miss?

1. **Indirect process execution.** If someone wraps `Process` in a helper function and calls the helper, the auditor won't trace across function boundaries. The `waitUntilExit()` and `readDataToEndOfFile()` would be in separate scopes.

2. **DispatchGroup / async waiting.** If `waitUntilExit()` is replaced with `process.terminationHandler` or `DispatchGroup.wait()`, the auditor won't recognize the wait pattern.

3. **Process reuse.** If a `Process` variable is created in one function but `waitUntilExit()` is called in another (unlikely but possible), the scope-local analysis misses it.

4. **readabilityHandler pattern.** If someone uses `pipe.fileHandleForReading.readabilityHandler` (callback-based reading) instead of `readDataToEndOfFile()`, the auditor won't detect missing drainage because it only looks for the specific method name.

**Mitigation:** These are acceptable false negatives. The auditor catches the dominant pattern (direct `Process` + `Pipe` + `waitUntilExit` in one scope), which covers all 13 existing call sites and the most common way new code gets written. Cross-function analysis would require data-flow tracking that's disproportionate to the value — this is a rare pattern used in <1% of Swift codebases.

### Evasion — How could someone accidentally bypass the check?

1. **Using ProcessRunner.** The whole point — `ProcessRunner.run()` doesn't call `waitUntilExit()` or `readDataToEndOfFile()` directly, so the auditor won't flag it. This is correct behavior: the safe utility is the intended path.

2. **Wrapping in a helper.** If someone writes their own `runCommand()` helper with the deadlock inside, the auditor flags the helper but new callers of the helper are invisible. The fix: once `ProcessRunner` exists, the code review question becomes "why aren't you using ProcessRunner?"

### Performance Impact

- Scan time: Negligible. One additional SyntaxVisitor pass over `Sources/`. The visitor does no process spawning — pure AST walk.
- Pre-commit overhead: <0.5 seconds additional (measured against similar auditors like pointer-escape).

### Scope Limitation

The auditor only scans `Sources/`. Test code using `Process` directly (unlikely but possible in integration tests) would not be checked. This is consistent with other auditors that skip test targets.

---

## Alternatives Considered

### 1. Only fix the code, no auditor
Rejected: the pattern would recur. Every new `Process()` usage would need manual review.

### 2. Lint rule in SwiftLint
Rejected: we already have SwiftSyntax infrastructure; adding an external tool dependency for one rule isn't justified.

### 3. Runtime detection (process timeout)
Rejected: by the time you detect the hang at runtime, the quality gate is already stuck. Prevention via static analysis is better.

---

## Implementation Order

1. ProcessRunner utility (already created in QualityGateCore)
2. Design proposal (this document)
3. ProcessSafetyAuditor module (RED: tests first, then GREEN: implementation)
4. Migrate all 13 call sites to ProcessRunner
5. Verify: `quality-gate --check process-safety` passes on the codebase
6. Update 12_ENFORCEMENT.md with new check
