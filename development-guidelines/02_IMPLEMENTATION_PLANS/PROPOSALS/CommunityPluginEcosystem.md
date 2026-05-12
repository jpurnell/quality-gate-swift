# Design Proposal: Community Plugin Ecosystem

## 1. Problem

The quality gate system has grown to 22 checkers covering safety, concurrency, accessibility, documentation, ethics, and more. Every checker lives in-tree inside `quality-gate-swift`, registered in a hardcoded `allCheckers` array. This creates three structural barriers to community adoption:

| Barrier | Impact |
|---|---|
| **In-tree only development** | Contributing a new checker requires cloning quality-gate-swift, understanding the full module graph, and submitting a PR that touches the CLI registration code |
| **No standalone plugin SDK** | `QualityGateCore` exports the `QualityChecker` protocol but also pulls in Yams, internal configuration machinery, and the reporter stack — plugin authors cannot depend on a minimal, stable contract |
| **No dynamic discovery** | Adding a checker means editing `QualityGateCLI.swift` lines 119-151; there is no mechanism to load checkers from external SPM packages at build time or runtime |
| **No severity governance** | Rule severity is hardcoded per auditor; consumers cannot downgrade an error to a warning or disable a rule without forking the checker |
| **No plugin author tooling** | Each auditor module defines its own ad-hoc test helpers; there is no shared test harness or fixture library for writing checker tests |

The `QualityGateTypes` package (already extracted, versioned at 1.0.0) proves the architecture can support external consumers. The gap is extending that pattern to the full plugin contract.

## 2. Objective

Enable developers outside the core team to author, test, publish, and consume quality gate checkers as standalone Swift packages — without requiring changes to quality-gate-swift source code.

Specifically:

- A plugin author can create a new SPM package that depends only on `QualityGatePluginSDK`
- The quality gate CLI discovers and loads plugins declared in `.quality-gate.yml`
- Plugin checkers participate in `--check all`, `--fix`, reporting (terminal/JSON/SARIF), and `--continue-on-failure` identically to built-in checkers
- Consumers can override severity per rule and disable specific rules from any checker (built-in or plugin)
- A `QualityGateTestKit` package provides test fixtures and assertion helpers so plugin authors can write tests without reverse-engineering internal patterns

## 3. Architecture

### 3.1 Package Extraction: QualityGatePluginSDK

Extract the minimal plugin contract from `QualityGateCore` into a new package with zero transitive dependencies beyond Foundation and `QualityGateTypes`:

```
QualityGatePluginSDK/
├── Sources/
│   └── QualityGatePluginSDK/
│       ├── QualityChecker.swift        // Protocol (re-exported from Core)
│       ├── FixableChecker.swift         // Protocol (re-exported from Core)
│       ├── CheckResult.swift            // Result container
│       ├── Diagnostic.swift             // Violation representation
│       ├── PluginMetadata.swift         // NEW: version, author, homepage
│       └── PluginRegistration.swift     // NEW: entry-point protocol
└── Package.swift                        // Depends only on QualityGateTypes
```

**Key design constraint:** This package must never depend on SwiftSyntax, Yams, ArgumentParser, or any other heavy dependency. Plugin authors who need SwiftSyntax add it to their own package. The SDK is the contract, not the implementation toolkit.

**PluginMetadata** provides discovery and compatibility information:

```swift
public struct PluginMetadata: Sendable, Codable {
    public let identifier: String          // Reverse-DNS: "com.example.my-checker"
    public let displayName: String
    public let version: String             // SemVer: "1.2.0"
    public let author: String
    public let homepage: String?
    public let minimumSDKVersion: String   // "1.0.0" — for compatibility gating
    public let tags: [String]              // ["swift-concurrency", "memory-safety"]
}
```

**PluginRegistration** is the entry-point contract:

```swift
public protocol QualityGatePlugin: Sendable {
    static var metadata: PluginMetadata { get }
    static func createCheckers() -> [any QualityChecker]
}
```

A plugin package exposes a single type conforming to `QualityGatePlugin`. The CLI discovers it by convention (see 3.2).

### 3.2 Plugin Discovery

Plugins are declared in `.quality-gate.yml` and resolved as SPM dependencies at build time. This avoids dynamic linking, `dlopen`, or any runtime loading — the plugin is compiled into the quality gate binary when the consumer adds it.

**Configuration schema addition:**

```yaml
plugins:
  - package: "https://github.com/example/qg-plugin-firebase-analytics"
    version: "1.0.0"
    checkers:
      - firebase-consent    # Opt-in to specific checkers
      - firebase-pii-guard

  - package: "https://github.com/example/qg-plugin-vapor-safety"
    version: "2.1.0"
    # Omitting 'checkers' enables all checkers from this plugin
```

**Resolution mechanism:** The CLI uses a two-phase approach:

1. **Build-time resolution**: A `quality-gate resolve-plugins` command reads `.quality-gate.yml`, generates a `PluginManifest.swift` file that imports each plugin package and collects their `createCheckers()` output into a unified registry. This file is compiled alongside the CLI.

2. **Fallback for pre-built binaries**: For consumers using the CLI as a pre-built binary (Homebrew, Mint), plugins are loaded from a `~/.quality-gate/plugins/` directory where each plugin is a compiled `.artifactbundle`. This is a v2 concern and explicitly out of scope for this proposal.

**Why not runtime `dlopen`?** Swift's lack of stable ABI for protocol conformance across separately compiled modules makes dynamic loading fragile. SPM build-time resolution is the idiomatic Swift approach and guarantees type safety.

### 3.3 Severity Override System

Add per-rule severity overrides to `.quality-gate.yml`:

```yaml
overrides:
  # Built-in rules
  safety.force-unwrap: warning          # Downgrade from error
  doc-coverage.undocumented-public: off  # Disable entirely
  context.missing-consent-guard: error   # Upgrade from warning

  # Plugin rules
  firebase-consent.missing-att: warning
  firebase-pii-guard.email-in-log: error
```

**Override semantics:**

| Override | Effect |
|---|---|
| `error` | Escalate to gate-failing severity |
| `warning` | Demote to advisory (does not fail gate unless `--strict`) |
| `info` | Informational only, never fails gate |
| `off` | Suppress entirely — diagnostic is not emitted |

**Implementation:** The CLI applies overrides after collecting diagnostics from each checker, before passing results to the reporter. This keeps checker implementations pure — they always emit their natural severity, and the consumer's configuration layer adjusts.

### 3.4 Plugin Test Harness: QualityGateTestKit

```
QualityGateTestKit/
├── Sources/
│   └── QualityGateTestKit/
│       ├── CheckerTestCase.swift       // Helpers for running checkers against source strings
│       ├── SourceFixtures.swift         // Common Swift source patterns for testing
│       ├── DiagnosticAssertions.swift   // #expect-based assertion helpers
│       └── ConfigurationBuilders.swift  // Test configuration factory
└── Package.swift                        // Depends on QualityGatePluginSDK + Testing
```

**Core testing API:**

```swift
/// Run a checker against inline Swift source and return diagnostics.
public func audit(
    _ source: String,
    with checker: some QualityChecker,
    configuration: Configuration = .default
) async throws -> CheckResult

/// Assert a specific rule was triggered at a specific line.
public func expectDiagnostic(
    in result: CheckResult,
    ruleId: String,
    severity: Diagnostic.Severity,
    atLine line: Int,
    sourceLocation: SourceLocation = #_sourceLocation
)

/// Assert no diagnostics were emitted.
public func expectClean(
    _ result: CheckResult,
    sourceLocation: SourceLocation = #_sourceLocation
)
```

This replaces the ad-hoc `TestHelpers.swift` pattern currently duplicated across auditor test targets.

### 3.5 Plugin Author Template

A template repository (`quality-gate-plugin-template`) provides the scaffolding:

```
quality-gate-plugin-template/
├── Sources/
│   └── MyPlugin/
│       ├── MyPlugin.swift              // QualityGatePlugin conformance
│       └── MyChecker.swift             // QualityChecker implementation
├── Tests/
│   └── MyPluginTests/
│       └── MyCheckerTests.swift        // Using QualityGateTestKit
├── Package.swift                        // Depends on QualityGatePluginSDK + QualityGateTestKit
├── .quality-gate.yml                    // Self-checks with quality-gate
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

The template includes a working example checker (a simple "flag TODO comments" rule) with full test coverage, demonstrating the red/green/refactor cycle for plugin development.

## 4. Configuration Schema (Complete)

The full `.quality-gate.yml` schema after this proposal:

```yaml
# Existing fields (unchanged)
excludePatterns: []
enabledCheckers: []           # Empty = all enabled
parallelWorkers: 4

# NEW: Plugin declarations
plugins:
  - package: "https://github.com/example/qg-plugin-name"
    version: "~> 1.0"         # SPM version requirement syntax
    checkers: []               # Empty or omitted = all from plugin

# NEW: Per-rule severity overrides
overrides:
  rule-id: error | warning | info | off

# Existing per-checker config sections (unchanged)
concurrency:
  justificationKeyword: "Justification:"
security:
  enabledRules: []
# ... etc
```

**Plugin configuration sections:** Plugins declare their configuration key in `PluginMetadata.identifier`. The consumer adds a section using that key:

```yaml
# Plugin-specific configuration
com.example.firebase-analytics:
  excludePaths: ["Sources/Legacy/**"]
  minConsentCheckDistance: 5
```

The CLI passes the raw YAML dictionary for that key to the plugin's checkers via a new `pluginConfiguration: [String: Any]` parameter on the `check` method. This avoids requiring the CLI to know plugin config schemas at compile time.

## 5. API Versioning Contract

The `QualityGatePluginSDK` follows semantic versioning with these guarantees:

| Change type | Version bump | Example |
|---|---|---|
| New optional method on `QualityChecker` with default implementation | Minor | Adding `var tags: [String]` with default `[]` |
| New type added to SDK | Minor | Adding `PluginCapability` enum |
| Required method signature change on `QualityChecker` | Major | Changing `check(configuration:)` parameter type |
| Removing a public type or method | Major | Removing `FixableChecker` |
| Bug fix in `CheckResult` equality logic | Patch | Fixing `Equatable` conformance |

**Stability rule:** The `QualityChecker` protocol is frozen after SDK 1.0.0. New capabilities are added via optional protocol extensions or new protocols that plugins can optionally adopt. This follows the same pattern as SwiftUI's `View` protocol — the core requirement is minimal, capabilities are layered.

**Minimum SDK version gating:** The CLI reads `PluginMetadata.minimumSDKVersion` and refuses to load plugins compiled against a newer SDK version than the CLI ships with, emitting a clear diagnostic:

```
error: Plugin 'firebase-analytics' requires QualityGatePluginSDK >= 2.0.0,
       but this CLI ships SDK 1.3.0. Update your quality-gate installation.
```

## 6. Governance Model

### 6.1 Plugin Tiers

| Tier | Description | Requirements | Discovery |
|---|---|---|---|
| **Core** | Ships with quality-gate-swift | Full design proposal, TDD, 100% doc coverage, adversarial review | Built-in, always available |
| **Official** | Maintained by core team in separate repos | Design proposal, full test coverage, published to Swift Package Index | Listed in official plugin registry |
| **Community** | Third-party plugins | Must compile against published SDK, passes own tests | Discoverable via Swift Package Index tags |

### 6.2 Core Plugin Graduation

A community plugin may be proposed for promotion to Official tier by opening a design proposal against development-guidelines. Requirements:

1. Stable release (>= 1.0.0) with semantic versioning
2. Test coverage exercising all rules with positive and negative cases
3. Documentation covering all rules, configuration options, and known limitations
4. Active maintenance (responds to SDK version updates within one minor release cycle)
5. No dependency on packages outside the Swift ecosystem's common set (Foundation, SwiftSyntax, SwiftNIO)

### 6.3 Plugin Registry

An `official-plugins.json` file in the development-guidelines repository serves as the curated registry:

```json
{
  "schemaVersion": 1,
  "plugins": [
    {
      "identifier": "com.qualitygate.firebase-analytics",
      "repository": "https://github.com/quality-gate/qg-plugin-firebase",
      "description": "Firebase Analytics consent and PII guards",
      "tier": "official",
      "tags": ["analytics", "privacy", "firebase"],
      "minimumCLIVersion": "1.4.0"
    }
  ]
}
```

The CLI can optionally query this registry via `quality-gate list-plugins` to show available official and community plugins. This is informational only — installation still requires adding the package to `.quality-gate.yml`.

## 7. Decoupled Prerequisites

Two components of this proposal are independently valuable and have been extracted into standalone proposals that can ship ahead of the full plugin ecosystem:

- **Severity Override System** (`SeverityOverrideSystem.md`): Per-rule severity overrides in `.quality-gate.yml`. Benefits all 22 existing built-in checkers immediately. No dependency on plugin infrastructure. This proposal's Section 3.3 references it as the mechanism for plugin rule governance.

- **QualityGateTestKit** (`QualityGateTestKit.md`): Standardized test harness replacing the three ad-hoc `TestHelpers.swift` files. Benefits built-in auditor development immediately. Becomes the published testing API for plugin authors when the SDK ships.

Both proposals can be implemented, shipped, and validated before any plugin infrastructure work begins. The implementation plan (Section 9) assumes these are completed first.

## 8. Migration Path for Built-in Checkers

This proposal does not move existing checkers out of quality-gate-swift. The migration path is:

1. **Phase 1 (this proposal):** Extract SDK, build discovery mechanism, ship template. All 22 built-in checkers continue to live in-tree and are compiled directly into the CLI.

2. **Phase 2 (future):** Built-in checkers adopt the same `QualityGatePlugin` entry-point protocol internally, proving the contract works for real-world checkers before community authors depend on it.

3. **Phase 3 (future, optional):** Domain-specific checkers (MCPReadinessAuditor, ContextAuditor) could be extracted into Official tier plugins, reducing core binary size for consumers who do not need them. This is explicitly optional — there is no urgency to extract working code.

## 9. Adversarial Review

### What could go wrong with this architecture?

**SPM build-time resolution is slow for many plugins.** Each plugin adds a dependency to the consumer's package graph. Ten plugins with transitive dependencies could materially slow `swift build`. Mitigation: the official recommendation caps plugins at 5-8, and the `checkers:` filter in `.quality-gate.yml` prevents unused checkers from running. Build time is an SPM concern, not a quality-gate concern, and improves with each Swift release.

**The `pluginConfiguration: [String: Any]` escape hatch is type-unsafe.** Passing raw YAML dictionaries to plugins loses compile-time type checking. This is a deliberate trade-off: the alternative (requiring the CLI to know every plugin's config schema) defeats the purpose of decoupled plugins. Plugins are responsible for validating their own configuration and emitting clear diagnostics for invalid values. `QualityGateTestKit` includes helpers for testing configuration validation.

**Plugin authors may depend on SwiftSyntax version X while the CLI pins version Y.** SPM resolves to a single version per package, so version conflicts surface as build errors, not silent failures. The SDK itself does not depend on SwiftSyntax; plugins that need it declare their own dependency. If a consumer's plugin set has conflicting SwiftSyntax requirements, SPM reports the conflict at resolution time. This is the correct behavior.

**Community plugins could emit misleading diagnostics.** A poorly written plugin could flag correct code, confuse users, and erode trust in the entire quality gate. Mitigation: the tier system separates core/official (reviewed) from community (use at your own risk). The severity override system lets consumers silence noisy rules without removing the plugin entirely. The `--check` flag lets consumers run specific checkers, skipping untrusted ones.

### Strongest case for a different approach

A critic might argue for runtime plugin loading via compiled bundles (`.artifactbundle`) rather than build-time SPM resolution. This would let pre-built CLI binaries (Homebrew) load plugins without recompilation. The counter: Swift's ABI stability for protocol conformance across separately compiled modules is not guaranteed for non-Apple platforms, and quality-gate targets both macOS and Linux. Build-time resolution is the only approach that works reliably today. Artifact bundles can be added as a v2 optimization once Swift's cross-module ABI stabilizes further.

### What an experienced critic would say

"You are designing a plugin marketplace before you have a single external plugin author. Ship the SDK and template. Skip the registry, the tier system, and the graduation process until you have three community plugins that actually exist." This is fair. The implementation plan (Section 10) front-loads the SDK and template, deferring governance infrastructure to later phases.

## 10. Implementation Plan

| # | Step | Effort | Dependencies |
|---|---|---|---|
| 1 | Create `QualityGatePluginSDK` package with `QualityChecker`, `FixableChecker`, `CheckResult`, `Diagnostic`, `PluginMetadata`, `PluginConfiguration`, `QualityGatePlugin` protocol (Swift 5.9+) | Medium | QualityGateTypes 1.0.0 |
| 2 | Create `QualityGateTestKit` package with `audit()`, `expectDiagnostic()`, `expectClean()`, configuration builders | Medium | QualityGatePluginSDK |
| 3 | Refactor `QualityGateCore` to re-export from `QualityGatePluginSDK` (preserves source compatibility for built-in checkers) | Small | Step 1 |
| 4 | Implement severity override system in CLI: parse `overrides:` from `.quality-gate.yml`, apply post-check | Medium | Yams config parsing |
| 5 | Implement `plugins:` config parsing and `resolve-plugins` command that generates `PluginManifest.swift` | Large | Step 1, ArgumentParser |
| 6 | Implement plugin sandbox: child process execution with `sandbox-exec` (macOS) / `seccomp-bpf` (Linux), JSON marshaling of `SourceFile` data via stdin/stdout, wall-clock timeout enforcement | Large | Step 1 |
| 7 | Implement plugin loading in CLI run loop: merge sandboxed plugin checkers into `allCheckers`, pass `PluginConfiguration`, enforce `--fix-plugins` gate | Medium | Steps 3, 5, 6 |
| 8 | Implement `diff-plugins` command: resolve two versions of a plugin, run both against the same source tree, compute diagnostic delta, output SARIF diff report | Medium | Steps 6, 7 |
| 9 | Create `quality-gate-plugin-template` repository with example checker, tests, CI, and documentation | Small | Steps 1, 2 |
| 10 | Write plugin author guide documenting SDK, testing, publishing, sandboxing constraints, and configuration patterns | Small | Steps 1, 2, 9 |
| 11 | Migrate one built-in checker (ContextAuditor) to use `QualityGatePlugin` entry-point internally as proof-of-concept | Medium | Steps 3, 7 |
| 12 | Create `official-plugins.json` registry and `list-plugins` CLI command | Small | Step 5 |

## 11. Success Criteria

- A new Swift package depending only on `QualityGatePluginSDK` can define a checker that flags `// TODO:` comments with `warning` severity
- That package's tests use `QualityGateTestKit` to verify the checker flags `// TODO: fix this` and passes `// FIXME: done`
- A consumer adds the plugin to `.quality-gate.yml` under `plugins:`, runs `quality-gate resolve-plugins && quality-gate --check all`, and sees the plugin's diagnostics in terminal and SARIF output
- The consumer overrides `todo-checker.todo-comment: off` in `.quality-gate.yml` and the diagnostic is suppressed
- All 22 existing built-in checkers continue to work identically with zero source changes to their implementations
- Plugin checkers execute in a sandboxed child process with no network access, no process spawning, and read-only filesystem scoped to source directories
- A plugin that attempts to write to disk, spawn a subprocess, or exceed its time budget is terminated with a clear diagnostic identifying the violation
- `quality-gate diff-plugins --from 1.0.0 --to 1.1.0` shows the diagnostic delta between two plugin versions run against the same source tree, in SARIF format
- `--fix-plugins` is required to apply plugin-authored fixes; `--fix` alone applies only core checker fixes
- `QualityGatePluginSDK` targets Swift 5.9+ for the contract surface; the CLI targets Swift 6.2+
- `QualityGatePluginSDK` has zero dependencies beyond Foundation and `QualityGateTypes`
- `QualityGatePluginSDK` achieves 100% public API doc coverage

## 12. Decisions

1. **The SDK will not ship SwiftSyntax utilities.** Many checkers need AST walking, and a `QualityGateSyntaxKit` companion package could provide common visitors. However, SwiftSyntax is non-core to the plugin contract and must not become an explicit dependency. Plugin authors depend on SwiftSyntax directly in their own packages. If common visitor patterns emerge from real community plugins, a companion package can be extracted later — but the SDK stays minimal.

2. **Plugins support `--fix` with a separate opt-in gate.** The `FixableChecker` protocol ships in the SDK from day one. The CLI adds a `--fix-plugins` flag (default off) as a distinct opt-in from `--fix`. This preserves the safety model: consumers explicitly trust plugin-authored code modifications separately from built-in fixes. The existing `--fix` flag continues to apply only to core checkers.

3. **`pluginConfiguration` uses a `PluginConfiguration` wrapper with typed access.** Rather than raw `[String: Any]` or requiring `Codable` (which would force a Yams dependency into the SDK), the SDK provides a `PluginConfiguration` wrapper offering typed access (`config.value(forKey: "maxDistance", as: Int.self, default: 10)`) alongside raw dictionary access. This keeps Yams out of the SDK while giving plugin authors type safety for common cases.

4. **The SDK targets Swift 5.9 for maximum approachability; the CLI stays modern.** The SDK contract is protocols, structs, and enums — types that do not require language features beyond Swift 5.9. `Sendable` enforcement, `async`/`await`, and existential `any` all work at 5.9. Targeting 5.9 for the SDK maximizes the potential plugin author base without introducing backward-compatibility shims, because the contract surface is intentionally simple enough not to need them. The CLI and built-in checkers continue to target the latest Swift release (6.2+) and adopt new language features freely. This separation is deliberate: the SDK is a stable contract that changes slowly, the CLI is an implementation that moves fast.

5. **Plugins run in a sandbox with version-diff comparison.** Plugin execution is sandboxed from v1. The sandbox constrains plugin checkers to:
   - **Read-only filesystem access** scoped to the `Sources/` and `Tests/` directories passed via `check(configuration:)`
   - **No network access** during the check phase
   - **No process spawning** — plugins analyze source text, they do not invoke compilers or external tools
   - **Memory and time budgets** — the CLI enforces per-plugin wall-clock limits (configurable, default 30s) and terminates checkers that exceed them

   **Version-diff mode:** The CLI supports `quality-gate diff-plugins --from 1.0.0 --to 1.1.0` which runs both versions of a plugin against the same source tree and reports the diagnostic delta: new rules added, rules removed, severity changes, and diagnostics that appeared or disappeared. This lets consumers evaluate a plugin upgrade before committing to it — not just "does the new version pass" but "what changed in its behavior." The diff output uses the same SARIF format as the main gate, enabling CI integration for plugin upgrade reviews.

   Implementation leverages Swift's process isolation: each plugin runs in a child process with a restricted sandbox profile (macOS `sandbox-exec`, Linux `seccomp-bpf`). The CLI marshals `SourceFile` data to the plugin process via stdin/stdout JSON, collects `CheckResult` responses, and terminates the process after completion. This is heavier than in-process execution but provides genuine isolation rather than trust-based security.

## 13. Open Questions

No open questions remain. All design decisions have been resolved.

---

**Date:** 2026-04-29
**Author:** Justin Purnell + Claude Opus 4.6
