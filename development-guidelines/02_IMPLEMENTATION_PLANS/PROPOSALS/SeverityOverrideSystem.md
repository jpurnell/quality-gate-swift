# Design Proposal: Severity Override System

## 1. Problem

Rule severity is hardcoded in every auditor. A `safety.force-unwrap` is always `.error`, a `logging.silent-try` is always `.warning`, and there is no configuration surface to change this. The only severity-adjacent control is `--strict`, which promotes all warnings to failures at the exit-code level but does not change the diagnostics themselves.

This creates two friction points:

| Friction | Example |
|---|---|
| **Cannot adopt incrementally** | A team adding quality-gate to a large existing codebase cannot downgrade `doc-coverage.undocumented-public` to `warning` during a migration period — they must either fix everything or disable the entire checker |
| **Cannot tune for project context** | A CLI tool with no UI has no use for `accessibility.*` rules but cannot suppress individual rules without removing the checker, losing the rules that do apply |

The Community Plugin Ecosystem proposal (Section 3.3) depends on this system for plugin rule governance. However, severity overrides are independently valuable for the 22 existing built-in checkers and should ship first.

## 2. Objective

Allow consumers to override the severity of any diagnostic rule — built-in or plugin — via `.quality-gate.yml`, without modifying auditor source code.

## 3. Proposed Design

### 3.1 Configuration Schema

Add an `overrides` section to `.quality-gate.yml`:

```yaml
overrides:
  safety.force-unwrap: warning
  doc-coverage.undocumented-public: info
  context.missing-consent-guard: error
  logging.print-statement: off
  recursion.convenience-init-self-loop: error
```

**Override values:**

| Value | Effect |
|---|---|
| `error` | Escalate to gate-failing severity |
| `warning` | Demote to advisory (does not fail gate unless `--strict`) |
| `info` | Informational only, never fails gate |
| `off` | Suppress entirely — diagnostic is not emitted or counted |

**Rule ID format:** `checker-id.rule-id` as already emitted by auditors in `Diagnostic.ruleId`. Auditors that do not set `ruleId` cannot be overridden per-rule — only per-checker via `enabledCheckers`.

### 3.2 Override Application Point

Overrides are applied in the CLI after each checker returns its `CheckResult`, before results are passed to the reporter. This keeps auditor implementations pure — they always emit their natural severity.

```
Auditor.check() → CheckResult → applyOverrides() → Reporter.report()
                                       ↑
                              reads overrides from
                              Configuration.overrides
```

**Processing logic:**

1. For each `Diagnostic` in the `CheckResult`:
   - Look up `diagnostic.ruleId` in the overrides map
   - If override is `off`: remove the diagnostic from the result
   - If override is `error`, `warning`, or `info`: replace `diagnostic.severity` with the override value
2. Recompute `CheckResult.Status` from the modified diagnostics:
   - Any `.error` diagnostic → `.failed`
   - Any `.warning` diagnostic (no errors) → `.warning`
   - No diagnostics or all `.info` → `.passed`

### 3.3 Override Reporting

When overrides modify a result, the reporter annotates the change so consumers understand why severity differs from the auditor's default:

**Terminal output:**
```
⚠ safety.force-unwrap (overridden from error → warning)
  Sources/Parser.swift:42:10 — Force unwrap of optional value
```

**SARIF output:** The override is recorded in the `properties` bag of each SARIF result:
```json
{
  "ruleId": "safety.force-unwrap",
  "level": "warning",
  "properties": {
    "originalSeverity": "error",
    "overriddenBy": ".quality-gate.yml"
  }
}
```

**JSON output:** Includes an `override` field on modified diagnostics:
```json
{
  "ruleId": "safety.force-unwrap",
  "severity": "warning",
  "override": { "from": "error", "source": ".quality-gate.yml" }
}
```

### 3.4 Wildcard Overrides

Support checker-level wildcards for bulk overrides:

```yaml
overrides:
  accessibility.*: off          # Disable all accessibility rules
  doc-coverage.*: warning       # Demote all doc-coverage rules to warning
  safety.force-unwrap: error    # Specific rules take precedence over wildcards
```

**Precedence:** Specific rule overrides take precedence over wildcards. If both `safety.*: warning` and `safety.force-unwrap: error` are present, `force-unwrap` is `.error` and all other safety rules are `.warning`.

### 3.5 Interaction with --strict

`--strict` operates on the final severity after overrides are applied. If a consumer overrides `safety.force-unwrap` to `warning`, `--strict` will treat it as a failure. This is correct — `--strict` means "treat warnings as errors" regardless of how the warning was produced.

## 4. Implementation

### 4.1 Configuration Extension

Add to `Configuration`:

```swift
public struct SeverityOverride: Sendable, Codable, Equatable {
    public enum OverrideLevel: String, Sendable, Codable {
        case error
        case warning
        case info
        case off
    }
    public let pattern: String      // "safety.force-unwrap" or "safety.*"
    public let level: OverrideLevel
}

// In Configuration:
public var overrides: [String: SeverityOverride.OverrideLevel]
```

### 4.2 Override Processor

A new `OverrideProcessor` struct in `QualityGateCore`:

```swift
public struct OverrideProcessor: Sendable {
    private let overrides: [String: SeverityOverride.OverrideLevel]

    public func apply(to result: CheckResult) -> CheckResult
}
```

This struct is stateless and testable in isolation.

### 4.3 CLI Integration

In `QualityGateCLI.swift`, after each checker's `check()` call completes:

```swift
let rawResult = try await checker.check(configuration: configuration)
let result = overrideProcessor.apply(to: rawResult)
```

## 5. Implementation Plan

| # | Step | Effort | Dependencies |
|---|---|---|---|
| 1 | Add `overrides` field to `Configuration` struct with YAML decoding | Small | Yams |
| 2 | Implement `OverrideProcessor` with exact-match and wildcard resolution, precedence logic | Medium | QualityGateCore |
| 3 | Write tests: exact override, wildcard override, precedence, `off` suppression, status recomputation | Medium | Step 2 |
| 4 | Integrate `OverrideProcessor` into CLI run loop between check and report | Small | Steps 2, 3 |
| 5 | Update `TerminalReporter` to annotate overridden diagnostics | Small | Step 2 |
| 6 | Update `SARIFReporter` and `JSONReporter` with override metadata | Small | Step 2 |
| 7 | Document override syntax in plugin author guide and CLI `--help` | Small | Step 4 |

## 6. Success Criteria

- `overrides: { safety.force-unwrap: warning }` in `.quality-gate.yml` changes the diagnostic severity from `.error` to `.warning` and the checker status from `.failed` to `.warning`
- `overrides: { logging.print-statement: off }` suppresses the diagnostic entirely — it does not appear in any reporter output
- `overrides: { accessibility.*: off }` suppresses all accessibility rules
- `overrides: { accessibility.*: off, accessibility.missing-label: error }` suppresses all accessibility rules except `missing-label`, which is escalated to `.error`
- `--strict` combined with an override to `warning` still fails the gate
- Overridden diagnostics show their original severity in terminal, SARIF, and JSON output
- Auditor source code is unchanged — no auditor is modified to support overrides
- Invalid rule IDs in `overrides:` produce a `.warning` diagnostic from the CLI itself (typo detection)

## 7. Open Questions

1. **Should invalid override keys produce errors or warnings?** A typo like `safty.force-unwrap` would silently do nothing. Recommendation: the CLI emits a `.warning` diagnostic listing any override keys that did not match any emitted rule ID across the entire run. This catches typos without failing the gate for a configuration issue.

2. **Should overrides be scoped to file paths?** A team might want `doc-coverage.*: off` only for `Sources/Generated/**`. Recommendation: defer path-scoped overrides to v2. Per-rule overrides cover the primary use case; path scoping adds configuration complexity that should be driven by real demand.

---

**Date:** 2026-04-29
**Author:** Justin Purnell + Claude Opus 4.6
