# Quality Gate Swift — Guide

A comprehensive guide to the vision, design, architecture, and practical usage of quality-gate-swift.

## Table of Contents

- [Why Quality Gate?](#why-quality-gate)
- [Design Philosophy](#design-philosophy)
- [Architecture](#architecture)
- [Getting Started](#getting-started)
- [Understanding Checkers](#understanding-checkers)
- [Configuration](#configuration)
- [Integrating with Your Workflow](#integrating-with-your-workflow)
- [Writing Custom Checkers](#writing-custom-checkers)
- [DocC Documentation](#docc-documentation)

---

## Why Quality Gate?

Swift has strong compile-time guarantees, but the compiler can't catch everything. Force unwraps crash at runtime. Concurrency violations cause data races. Undocumented public APIs become maintenance burdens. Security anti-patterns slip through code review. Test suites pass while containing no assertions.

Existing tools address some of these problems individually — SwiftLint handles style, the compiler handles types — but there's a gap between "it compiles" and "it's correct, safe, and maintainable."

Quality Gate fills that gap. It's a single tool that runs 23 independent checkers covering correctness, safety, security, documentation, accessibility, and project health. Each checker produces structured diagnostics with file paths, line numbers, rule IDs, and suggested fixes. Results flow into your terminal, your CI pipeline, and GitHub Code Scanning via SARIF.

The goal is a single command — `quality-gate` — that tells you whether your Swift project is ready to ship.

## Design Philosophy

### AST-first, not regex

Every code analysis rule in Quality Gate walks the SwiftSyntax abstract syntax tree. This is a deliberate choice over regex-based or tree-sitter-based scanning.

Regex scanners match text patterns. They can't distinguish a `fatalError()` call from a string containing the word "fatalError" or a doc comment discussing when to use it. They produce false positives that train developers to ignore warnings.

Quality Gate's SafetyAuditor, for example, visits `FunctionCallExprSyntax` nodes. It knows whether `fatalError` appears in executable code, a string literal, or a comment. The ConcurrencyAuditor understands actor isolation boundaries. The RecursionAuditor builds a call graph from the AST and walks it to find cycles.

The tradeoff is implementation complexity — AST visitors are harder to write than regex patterns. But the result is rules that developers trust, because they don't cry wolf.

### Modular by design

Each checker is an independent Swift Package Manager module with its own source directory, test suite, and DocC catalog. The CLI imports all 23, but you can depend on individual modules:

```swift
// Only pull in what you need
.product(name: "ConcurrencyAuditor", package: "quality-gate-swift"),
.product(name: "SafetyAuditor", package: "quality-gate-swift"),
```

This matters for three reasons:

1. **Build times** — depending on two checkers doesn't compile the other twenty-one
2. **Testability** — each module has focused tests that run in seconds, not minutes
3. **Extensibility** — new checkers don't touch existing code

### Structured diagnostics

Every checker returns the same type: `CheckResult` containing an array of `Diagnostic` values. A diagnostic carries:

- **severity** — `.error`, `.warning`, or `.note`
- **message** — human-readable description
- **filePath / lineNumber / columnNumber** — precise location
- **ruleId** — machine-readable identifier (e.g., `security.hardcoded-secret`)
- **suggestedFix** — optional remediation text

This uniform structure means terminal output, JSON, and SARIF all come for free. It also means severity overrides work across every checker — you can downgrade `force-unwrap` to a warning or upgrade `insecure-transport` to an error in your `.quality-gate.yml`.

### Dogfooding

Quality Gate runs itself on every push. The CI workflow at `.github/workflows/quality-gate.yml` builds the tool and immediately runs it against its own codebase. If a checker produces a false positive, the team that wrote it feels the pain immediately.

This feedback loop keeps rules honest. A checker that generates noise gets fixed or removed — it can't hide behind "well, it works on other projects."

## Architecture

### The QualityChecker protocol

Every checker conforms to a single protocol:

```swift
public protocol QualityChecker: Sendable {
    var id: String { get }
    var name: String { get }
    func check(configuration: Configuration) async throws -> CheckResult
}
```

The `id` is a kebab-case string used on the command line (`--check concurrency`). The `name` is human-readable for terminal output. The `check` method receives the project configuration and returns structured results.

Checkers that support auto-remediation also conform to `FixableChecker`:

```swift
public protocol FixableChecker: QualityChecker {
    var fixDescription: String { get }
    func fix(diagnostics: [Diagnostic], configuration: Configuration) async throws -> FixResult
}
```

### Module dependency graph

```
QualityGateTypes (external package)
       │
QualityGateCore (protocol, models, config, reporters)
       │
   ┌───┼───┬───┬───┬───┬───┬───┬───┬───┬── ... ──┐
   │   │   │   │   │   │   │   │   │   │          │
Safety Rec Conc Ptr FP  Mem Log Ctx Tst  ...    Access
Auditor    Aud  Esc Safe Life Aud Aud Qual        Aud
   │        │   │               │
   │    ┌───┘   │           ┌───┘
   └────┤       │           │
     SwiftSyntax + SwiftParser
                │
           IndexStoreDB (UnreachableCodeAuditor only)
```

All checkers depend on `QualityGateCore`. The twelve SwiftSyntax-based checkers additionally depend on `SwiftSyntax` and `SwiftParser`. Only `UnreachableCodeAuditor` requires `IndexStoreDB` for cross-file dead-code analysis.

`QualityGateTestKit` provides helpers for writing checker tests — fixture builders, diagnostic matchers, and configuration factories.

### Data flow

```
.quality-gate.yml ──→ Configuration
                          │
                          ▼
                    QualityGateCLI
                          │
               ┌──────────┼──────────┐
               ▼          ▼          ▼
          Checker A   Checker B   Checker C
               │          │          │
               ▼          ▼          ▼
          CheckResult CheckResult CheckResult
               │          │          │
               └──────────┼──────────┘
                          │
                   OverrideProcessor (apply severity overrides)
                          │
                          ▼
                    ReporterFactory
                    ┌─────┼─────┐
                    ▼     ▼     ▼
                Terminal JSON  SARIF
```

The CLI loads configuration, instantiates all checkers, runs the enabled subset sequentially, applies any severity overrides, and feeds results to the selected reporter.

## Getting Started

### Install

```bash
git clone https://github.com/jpurnell/quality-gate-swift.git
cd quality-gate-swift
swift build -c release
cp .build/release/quality-gate /usr/local/bin/
```

### First run

Navigate to any Swift package and run:

```bash
quality-gate
```

This runs all default checkers (everything except `disk-clean` and `mcp-readiness`, which are opt-in). You'll see output like:

```
==========================================
  Quality Gate Results
==========================================

✓ [build] PASSED (12.3s)
✓ [test] PASSED (45.1s)
✗ [safety] FAILED (1.8s)
  ✕ error: Force unwrap detected — Sources/App/User.swift:42:15 [force-unwrap]
  ✕ error: Hardcoded secret — Sources/App/Config.swift:8:5 [security.hardcoded-secret]
✓ [recursion] PASSED (0.9s)
✓ [concurrency] PASSED (1.1s)
✓ [doc-coverage] PASSED (0.3s)
  ℹ️  note: Documentation coverage: 94% (47/50 public APIs documented)

==========================================
❌ Quality Gate: FAILED
==========================================
```

### Fix issues

For checkers that support auto-fix, preview what would change:

```bash
quality-gate --fix --dry-run
```

Then apply:

```bash
quality-gate --fix
```

For issues that require manual intervention, the diagnostic tells you exactly where to look: file path, line number, rule ID, and often a suggested fix.

### Suppress false positives

If a warning is intentional, add an inline exemption comment:

```swift
// SAFETY: Non-nil guaranteed by storyboard instantiation
let controller = storyboard.instantiateInitialViewController()!
```

The exemption keyword is configurable via `.quality-gate.yml`:

```yaml
safetyExemptions:
  - "// SAFETY:"
  - "// REVIEWED:"
```

### Run specific checkers

For faster feedback during development, run only the checkers relevant to your current work:

```bash
# Just correctness checks
quality-gate --check recursion --check concurrency --check pointer-escape

# Everything except the slow ones
quality-gate --check all --exclude build --exclude test

# Only security
quality-gate --check safety
```

## Understanding Checkers

Quality Gate's 23 checkers fall into six categories. Here's what each category catches and why it matters.

### Correctness

These checkers find bugs that compile but crash or produce wrong results at runtime.

**RecursionAuditor** (`recursion`) — Catches infinite recursion patterns that the compiler silently accepts: convenience initializers that forward to themselves, computed properties that read their own value in their getter, protocol extension defaults that call the same method they're providing a default for. Also builds a call graph to detect mutual recursion without a base case.

**PointerEscapeAuditor** (`pointer-escape`) — Swift's `withUnsafe*` family gives you a pointer that's only valid inside the closure. Storing it, returning it, appending it to an array, or passing it as `inout` to an outer variable is undefined behavior. This checker tracks pointer lifetimes through the AST and flags escapes.

**ConcurrencyAuditor** (`concurrency`) — Enforces Swift 6 strict concurrency rules beyond what the compiler requires. Flags `@unchecked Sendable` without a justification comment, mutable stored properties on Sendable classes, `DispatchQueue` usage inside actor-isolated contexts, and `@MainActor` deinit methods that touch isolated state.

**FloatingPointSafetyAuditor** (`fp-safety`) — Detects `==` and `!=` comparisons on floating-point values (which fail due to representation error) and division operations without zero guards.

**MemoryLifecycleGuard** (`memory-lifecycle`) — Finds stored `Task` properties without corresponding cancellation in `deinit`, and strong `delegate` references that should be `weak`.

**UnreachableCodeAuditor** (`unreachable`) — Combines SwiftSyntax analysis (dead statements after `return`, constant `if` conditions, `switch` cases after unconditional patterns) with IndexStore cross-referencing to find truly unused symbols.

### Safety & Security

**SafetyAuditor** (`safety`) — Two visitors in one checker. The safety visitor flags crash-prone patterns: `!`, `as!`, `try!`, `fatalError()`, `precondition()`, `assertionFailure()`, `unowned`, `while true`, and `String(format:)`. The security visitor implements 10 OWASP Mobile Top 10 rules covering hardcoded secrets, command injection, weak crypto, insecure transport, eval-JS, SQL injection, insecure keychain, TLS bypass, path traversal, and SSRF. All rules use full AST context — they won't false-positive on string literals or comments.

**StochasticDeterminismAuditor** (`stochastic-determinism`) — Flags randomness sources (`Int.random`, `Double.random`, `Bool.random`, `Array.shuffled`, etc.) in production code that lack seed injection. Non-deterministic code is impossible to reproduce in tests or debug in production.

### Code Hygiene

**LoggingAuditor** (`logging`) — Catches `print()` and `NSLog()` in production code (should use `os.Logger`), empty `catch` blocks that silently swallow errors, and logger instances without privacy-level annotations. Supports file-level `// logging:` exemptions.

**TestQualityAuditor** (`test-quality`) — Audits your test code: exact floating-point assertions that should use `accuracy:`, test methods with no assertion calls, and unseeded randomness in test fixtures.

**ContextAuditor** (`context`) — An ethical-context checker: flags analytics calls without consent guards, location tracking without purpose strings, and data collection patterns that should have opt-out mechanisms.

**AccessibilityAuditor** (`accessibility`) — Scans SwiftUI views for accessibility violations: images and buttons without accessibility labels, hardcoded font sizes that ignore Dynamic Type, and UI that relies on color alone to convey information.

### Documentation

**DocCoverageChecker** (`doc-coverage`) — Uses SwiftSyntax to find every `public` declaration and checks whether it has a documentation comment. Reports coverage as a percentage and lists each undocumented symbol.

**DocLinter** (`doc-lint`) — Runs `swift package generate-documentation` and reports any DocC build errors.

### Project Health

**BuildChecker** (`build`) — Wraps `swift build` and parses its output into structured diagnostics. Compiler errors become `Diagnostic` values with file paths and line numbers.

**TestRunner** (`test`) — Wraps `swift test`, parses both Swift Testing and XCTest output formats, and reports failures as diagnostics.

**StatusAuditor** (`status`) — Detects drift between your project documentation (Master Plan, README) and actual code state: modules marked complete that don't exist, test counts that have drifted, stale "Last Updated" dates, roadmap phases marked current with all items done. Supports `--fix` to auto-patch provably-wrong content and `--bootstrap` to generate initial documents.

**DependencyAuditor** (`dependency-audit`) — Checks SPM dependency hygiene: `Package.resolved` in sync with `Package.swift`, no branch pins in production (use version tags), no local path overrides committed.

**ReleaseReadinessAuditor** (`release-readiness`) — Pre-release checklist: CHANGELOG has an entry for the current version, README has no placeholder text, source code has no bare `TODO` or `FIXME` markers without tracking references.

**SwiftVersionChecker** (`swift-version`) — Validates that the swift-tools-version in `Package.swift` meets the minimum supported version and optionally tests whether a version upgrade would succeed.

**MemoryBuilder** (`memory-builder`) — Generates and validates `.claude/memory/` files for Claude Code project memory. Ensures the memory index stays in sync with actual memory files.

### Specialty

**MCPReadinessAuditor** (`mcp-readiness`) — For projects implementing Model Context Protocol servers: cross-references JSON schema tool definitions against Swift `execute` implementations to find missing handlers, schema drift, and undocumented tools. Opt-in because most projects don't use MCP.

**DiskCleaner** (`disk-clean`) — Identifies and removes `.build/`, `.docc-build/`, and other build artifacts. Opt-in because it modifies the filesystem.

## Configuration

### The configuration file

Quality Gate looks for `.quality-gate.yml` in your project root. Every field is optional — the tool works with sensible defaults out of the box.

```yaml
# Limit parallel test workers (default: 80% of CPU cores)
parallelWorkers: 8

# Glob patterns for files/directories to skip
excludePatterns:
  - "**/Generated/**"
  - "**/Vendor/**"

# Comments that suppress safety/security warnings
safetyExemptions:
  - "// SAFETY:"
  - "// SECURITY:"

# Restrict which checkers run by default (empty = all non-opt-in)
enabledCheckers: []

# Build configuration for BuildChecker
buildConfiguration: debug

# Test filter for TestRunner
testFilter: ""

# Minimum documentation coverage (nil = 100%)
docCoverageThreshold: 80
```

### Per-checker configuration

Most checkers accept additional configuration under their own key:

```yaml
concurrency:
  justificationKeyword: "Justification:"
  allowPreconcurrencyImports:
    - Alamofire
    - Firebase

pointerEscape:
  allowedEscapeFunctions:
    - vDSP_fft_zip
    - vDSP_fft_zop

security:
  enabledRules: []  # empty = all 10 rules
  secretPatterns: [password, secret, apiKey, token]
  allowedHTTPHosts: [localhost, 127.0.0.1]

logging:
  allowPrintInTargets: ["QualityGateCLI"]
```

### Severity overrides

Override any rule's severity without modifying checker code:

```yaml
overrides:
  - ruleId: "force-unwrap"
    severity: warning    # downgrade from error
  - ruleId: "security.insecure-transport"
    severity: error      # upgrade from warning
```

## Integrating with Your Workflow

### GitHub Actions with SARIF

The most powerful integration: Quality Gate findings appear as inline annotations in pull request diffs.

```yaml
name: Quality Gate

on:
  push:
    branches: [main]
  pull_request:

jobs:
  quality-gate:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable

      - name: Build Quality Gate
        run: swift build -c release

      - name: Run Quality Gate
        run: >-
          .build/release/quality-gate
          --format sarif
          --continue-on-failure
          > results.sarif

      - name: Upload SARIF
        if: always()
        uses: github/codeql-action/upload-sarif@v2
        with:
          sarif_file: results.sarif
```

### Reusable workflow

Quality Gate provides a reusable workflow at `.github/workflows/quality-gate-reusable.yml` that other repositories can call:

```yaml
jobs:
  quality-gate:
    uses: jpurnell/quality-gate-swift/.github/workflows/quality-gate-reusable.yml@main
```

### Git hooks

For fast local feedback, wire up a pre-push hook with lightweight checkers:

```bash
#!/bin/bash
# .git/hooks/pre-push
quality-gate --check build --check safety --check recursion --check concurrency
```

Keep `build` and `test` out of pre-commit hooks (they're slow). Use them in pre-push or CI instead.

### SPM plugin

For projects that consume quality-gate-swift as a dependency:

```bash
swift package plugin quality-gate
swift package plugin quality-gate --check safety --check concurrency
```

### JSON output for custom tooling

```bash
quality-gate --format json | jq '.results[] | select(.status == "failed")'
```

The JSON format includes timing data, diagnostic counts, and suggested fixes — useful for dashboards, Slack notifications, or custom reporting.

### Security rule staleness

A built-in workflow (`.github/workflows/security-rule-staleness.yml`) checks security rule review dates bi-monthly and opens a GitHub issue when any rule exceeds its 365-day review window. This ensures security rules don't silently become outdated as the threat landscape evolves.

## Writing Custom Checkers

Quality Gate is designed to be extended. Create a new module, conform to `QualityChecker`, and register it in the CLI.

### Step 1: Create the module

Add a new target to `Package.swift`:

```swift
.target(
    name: "MyChecker",
    dependencies: [
        "QualityGateCore",
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
    ]
),
.testTarget(
    name: "MyCheckerTests",
    dependencies: ["MyChecker", "QualityGateTestKit"]
),
```

### Step 2: Implement the protocol

```swift
import QualityGateCore
import SwiftSyntax
import SwiftParser

public struct MyChecker: QualityChecker, Sendable {
    public let id = "my-checker"
    public let name = "My Checker"

    public init() {}

    public func check(configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now
        var diagnostics: [Diagnostic] = []

        // Walk Swift files with a syntax visitor
        let sourceFiles = try SwiftFileEnumerator.enumerate(
            at: FileManager.default.currentDirectoryPath,
            excluding: configuration.excludePatterns
        )

        for file in sourceFiles {
            let source = try String(contentsOfFile: file, encoding: .utf8)
            let tree = Parser.parse(source: source)
            let visitor = MyVisitor(filePath: file)
            visitor.walk(tree)
            diagnostics.append(contentsOf: visitor.diagnostics)
        }

        return CheckResult(
            checkerId: id,
            status: diagnostics.isEmpty ? .passed : .failed,
            diagnostics: diagnostics,
            duration: ContinuousClock.now - start
        )
    }
}
```

### Step 3: Write a syntax visitor

```swift
import SwiftSyntax

final class MyVisitor: SyntaxVisitor {
    let filePath: String
    var diagnostics: [Diagnostic] = []

    init(filePath: String) {
        self.filePath = filePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Your analysis logic here
        return .visitChildren
    }
}
```

### Step 4: Register in the CLI

Add your checker to the `allCheckers` array in `QualityGateCLI.swift`:

```swift
let allCheckers: [any QualityChecker] = [
    // ... existing checkers ...
    MyChecker(),
]
```

### Step 5: Add DocC documentation

Create `Sources/MyChecker/MyChecker.docc/MyChecker.md` with an overview, and optionally a `MyCheckerGuide.md` with detailed usage examples.

## DocC Documentation

Every checker module includes a DocC catalog with at least an overview article. Most also include a detailed guide covering rules, examples, and configuration.

### Building documentation locally

```bash
# Build docs for a specific module
swift package generate-documentation --target SafetyAuditor

# Preview in Xcode's documentation viewer
swift package generate-documentation --target QualityGateCore \
  --disable-indexing \
  --output-path .docc-build

# Build docs for all modules
for dir in Sources/*/; do
    module=$(basename "$dir")
    if [ -d "$dir/$module.docc" ]; then
        swift package generate-documentation --target "$module"
    fi
done
```

### What's documented

| Module | DocC Catalog Contents |
|--------|-----------------------|
| QualityGateCore | Protocol reference, `ImplementingCheckers` guide |
| SafetyAuditor | All safety + security rules, `ExemptionGuide` |
| ConcurrencyAuditor | Swift 6 concurrency rules, configuration guide |
| RecursionAuditor | Recursion patterns, call-graph analysis guide |
| PointerEscapeAuditor | Pointer lifetime rules, `withUnsafe*` guide |
| UnreachableCodeAuditor | Dead-code detection strategies guide |
| AccessibilityAuditor | SwiftUI accessibility rules guide |
| LoggingAuditor | Logging hygiene rules guide |
| TestQualityAuditor | Test quality rules guide |
| ContextAuditor | Ethical context rules guide |
| StatusAuditor | Status drift detection, auto-fix guide |
| FloatingPointSafetyAuditor | FP safety rules guide |
| StochasticDeterminismAuditor | Determinism rules guide |
| MemoryLifecycleGuard | Memory lifecycle rules guide |
| DependencyAuditor | Dependency hygiene guide |
| ReleaseReadinessAuditor | Release checklist guide |
| MCPReadinessAuditor | MCP schema validation guide |
| MemoryBuilder | Memory generation guide |
| QualityGateCLI | CLI usage reference |
| BuildChecker | Build checker reference |
| TestRunner | Test runner reference |
| DocLinter | Doc linter reference |
| DocCoverageChecker | Doc coverage reference |
| DiskCleaner | Disk cleaner reference |
| SwiftVersionChecker | Version checker reference |

The DocC catalogs are the authoritative reference for each module's rules, configuration options, and examples. Start with the README for an overview, use this guide for architecture and workflow integration, and consult the DocC documentation for deep dives into individual checkers.
