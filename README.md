# quality-gate-swift

**Static analysis for Swift 6, built on SwiftSyntax and the index store — plus three checkers that ask whether your documentation still compiles, still runs, and still tells the truth.**

46 checkers for correctness, safety, concurrency and security. AST-based rather than regex, so rules understand scope, type context and control flow. Terminal, JSON, SARIF and Xcode output. It runs its own checkers on every commit and every push.

> **Looking for testers.** If you try this and it misfires on your code, that is the most useful thing you can send — open an issue with the snippet. False positives are tracked and published per checker; see [Checkers report their own precision](#3-checkers-report-their-own-precision).

## Requirements

- **macOS 15+** — the package declares `.macOS(.v15)`. On macOS 14 it builds and then fails at launch with a dyld error.
- **Swift 6.2+** — the manifest is `swift-tools-version: 6.2`; earlier toolchains cannot parse it.
- **Linux: builds, tests and runs on Swift 6.2.** The suite runs in the official `swift:6.2`
  container, and the [Linux job](../../actions/workflows/linux.yml) is the live answer to how
  much of it passes — this sentence deliberately does not carry a number, because the first
  draft of it did and the next CI run falsified it within the hour. macOS is still the
  platform every release is cut against, and the one to pick if you have a choice. See
  [Install on Linux](#linux) for the two build flags it needs and
  [Honest limits](#honest-limits) for what is known to differ.

  This entry used to read "macOS only, today — Linux is not supported and not tested", on the
  grounds that `indexstore-db` includes `<dispatch/dispatch.h>` with no platform guard. That
  much was true; the conclusion was not. The toolchain ships the header, just not on the
  default include path, so the build needs two `-Xcxx` flags rather than a port of a C++
  dependency. The rest of the gap was a handful of Darwin names written in as literals —
  `/usr/bin/xcrun` as the compiler, `libIndexStore.dylib` as the library — each in a code path
  macOS always takes and nothing else ever had.

## Install

### macOS

```bash
git clone https://github.com/jpurnell/quality-gate-swift.git
cd quality-gate-swift
swift build -c release

# The binary needs its resource bundles beside it: SwiftPM resolves them relative
# to the executable, so copying the binary alone fails at runtime with
# "couldn't find bundle named quality-gate-swift_ControlMapping".
sudo cp .build/release/quality-gate /usr/local/bin/
sudo cp -R .build/release/quality-gate-swift_*.bundle /usr/local/bin/
```

### Linux

Tested on the official `swift:6.2` container. Both `-Xcxx` flags are required, not optional:
`indexstore-db`'s C++ sources include `<dispatch/dispatch.h>` and `Block.h` with no platform
guard, and the Swift toolchain ships both headers — just not on the default include path.
Without them the build fails in a C++ dependency, which is where the "macOS only" claim in
this README came from for longer than it was true.

```bash
git clone https://github.com/jpurnell/quality-gate-swift.git
cd quality-gate-swift
swift build -c release \
  -Xcxx -I/usr/lib/swift \
  -Xcxx -I/usr/lib/swift/Block

# Same requirement as macOS, different suffix: SwiftPM writes resource bundles as
# `.resources` directories here, not `.bundle`.
sudo cp .build/release/quality-gate /usr/local/bin/
sudo cp -R .build/release/quality-gate-swift_*.resources /usr/local/bin/
```

Run the same way on both:

```bash
quality-gate --check safety --check concurrency
```

## First run

Point it at any Swift package:

```
$ quality-gate --check safety --check fp-safety --check concurrency

==========================================
  Quality Gate Results
==========================================

✓ [safety] PASSED (1.15s)
  ℹ️  note: safety examined 656 files · 1 git-ignored directory, 1 nested package

✓ [concurrency] PASSED (89.80s)
  ℹ️  note: concurrency examined 656 files · 1 git-ignored directory, 1 nested package

✓ [fp-safety] PASSED (804ms)
  ℹ️  note: floating-point examined 656 files · 1 git-ignored directory, 1 nested package
```

Every checker prints what it examined, computed rather than hardcoded. A bare `quality-gate` runs the default set, which includes `build` and `test` — expect it to take as long as your build does.

```bash
quality-gate                                   # default set
quality-gate --check all --exclude test        # everything but the slow one
quality-gate --fix --dry-run                   # preview auto-fixes
quality-gate --format sarif > results.sarif    # GitHub Code Scanning
```

Adopting it on an existing codebase with a backlog? See [Suppression that expires](#2-suppression-that-expires) — `quality-gate adopt` gives you a green gate on day one without hiding anything permanently.

## Why not just SwiftLint?

Use both. They answer different questions, and SwiftLint is better at the one it asks.

SwiftLint is a **style and convention** engine with a large rule set, fast incremental runs and universal editor integration. If you want consistent formatting and idiom across a team, reach for that first.

This is a **correctness and safety** gate:

| | SwiftLint | quality-gate-swift |
|---|---|---|
| Analysis | Mostly syntactic | AST throughout, plus index-store symbol resolution across files |
| Cross-file reasoning | Limited | Call graphs, USR-based recursion detection, dead code via index cross-reference |
| Suppression | `// swiftlint:disable`, permanent | Dated debt that expires and comes back |
| Documentation | Not its job | Compiles, runs and fact-checks DocC articles |
| False positives | Not published | Measured and published per checker |
| Speed | Fast | Slower; some checkers need a build or an index |

It is slower and narrower. It is meant to sit beside SwiftLint, not replace it.

## Three things it does that other linters don't

### 1. Your documentation is a build artifact

A code sample in a DocC article is just a string. It can call a function you deleted two releases ago and nothing anywhere goes red. Three rungs close that:

| Rung | Checker | Asks | Default |
|---|---|---|---|
| 1 | `doc-code` | Do the article's fences assemble into one program that typechecks? | on |
| 2 | `doc-run` | Does that program run top to bottom without trapping — twice, identically? | opt-in |
| 3 | `doc-claims` | Do the figures the article publishes match what its own program computed? | opt-in |

This repository runs rungs 1 and 2 on every commit. Actual output, not a mock-up:

```
$ quality-gate --check doc-run
✓ [doc-run] PASSED (41.80s)
  ℹ️  note: 56 articles: 54 ran, 2 could not be built, 54 ran cleanly and
     reproducibly, 0 produced different output on a second run.
```

The two that could not be built are reported as **not run**, not as passes. The gap between articles *found* and articles *checked* is the difference between a coverage number and a fiction, so every documentation checker computes its own scope on every run. A scope claim written into prose goes stale; a computed one cannot.

### 2. Suppression that expires

Every linter's real failure is the `// swiftlint:disable` that outlives the person who wrote it. `quality-gate adopt` records each existing finding as **dated debt**:

```bash
quality-gate adopt --decay-days 180
```

Green gate on day one. New findings gate immediately. Every recorded debt comes due on a date, and `quality-gate re-verify` works the queue of what has expired — re-affirm consciously, or retire.

### 3. Checkers report their own precision

```bash
quality-gate calibrate --coverage
```

Per-checker sample counts and false-positive rates, with every override classified by root cause: `imprecise`, `structural`, `deferred`, `external`, or `expedient`. A checker whose findings are mostly waved away should have to say so.

## Highlights

- **AST-first analysis** — SwiftSyntax visitors instead of regex, so rules understand scope, type context and control flow; index-store-backed checkers resolve symbols across files
- **Modular** — every checker an independent SPM module with its own test target and DocC catalogue, so you can depend on one without the rest

<!-- generated:scale -->
- **120 targets** — 60 source, 60 test
- **46 registered checkers**
<!-- /generated:scale -->

- **Structured output** — terminal, JSON, SARIF 2.1.0, and Xcode Build Phase format
- **Auto-fix** — checkers conforming to `FixableChecker` patch issues with `--fix`, except where fixing would launder the defect (see [Honest limits](#honest-limits))
- **Read-only on strangers' code** — `--foreign` analyses a repo you don't own without writing to it; every write redirects to an overlay and `--fix` is refused
- **Self-dogfooding** — it runs its own checkers on every commit and every push

## Use as a dependency

```swift
dependencies: [
    .package(url: "https://github.com/jpurnell/quality-gate-swift.git", from: "3.4.0"),
]
```

Or as an SPM plugin:

```bash
swift package plugin quality-gate
```

## Checkers

### Correctness

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-correctness -->
| `unreachable` | UnreachableCodeAuditor | Dead code via SwiftSyntax + IndexStore cross-reference |
| `recursion` | RecursionAuditor | Self-forwarding inits, computed property cycles, mutual recursion via USR call-graph analysis |
| `concurrency` | ConcurrencyAuditor | Swift 6 strict concurrency: `@unchecked Sendable` justifications, mutable Sendable classes, actor isolation, cancellation checkpoints after `for await` loops |
| `pointer-escape` | PointerEscapeAuditor | Unsafe pointer escapes from `withUnsafe*` blocks |
| `fp-safety` | FloatingPointSafetyAuditor | Floating-point exact equality, unguarded division |
| `fallback` | FloatingPointSafetyAuditor | A NaN that traps an integer conversion, is clamped to a bound, is sorted into the last arm, or is answered for by a guard |
| `memory-lifecycle` | MemoryLifecycleGuard | Stored Tasks without cancellation, strong delegate references, cross-file lifecycle analysis |
| `process-safety` | ProcessSafetyAuditor | Pipe-buffer deadlock: waitUntilExit() before reading pipe output |
| `liveness` | LivenessAuditor | Blocking waits that declined an available deadline |
| `bounded-io` | BoundedIOAuditor | Unbounded blocking primitives called outside the audited kernel |
| `complexity` | ComplexityAnalyzer | Cognitive complexity per function, call-graph amplification, cross-module amplification, O(n) pattern detection |
| `legibility` | LegibilityAnalyzer | Advisory (never gates): central-but-unoriented modules, dependency cycles, over-public surface; emits a reading-order / module-map artifact |
<!-- /generated:checker-table-correctness -->

### Safety & Security

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-safety-security -->
| `safety` | SafetyAuditor | Force unwraps, force casts, `try!`, `fatalError`, OWASP Mobile Top 10 security rules |
| `stochastic-determinism` | StochasticDeterminismAuditor | Unseeded randomness in production code |
| `temporal-determinism` | TemporalDeterminismAuditor | Wall-clock nondeterminism: simulated sources stamping `.now`, and tests asserting on measured elapsed wall-clock time |
| `gpu-safety` | GPUSafetyAuditor | Metal kernels that index by thread id with no bound, and dispatches that round up — the conditions for silent out-of-bounds reads and writes |
| `keychain-secrets` | KeychainSecretsChecker | Credentials/tokens written to `UserDefaults` (plaintext plist, backup-swept) instead of the Keychain — key- and value-name secret detection with a Bool/Int-value guard |
| `privacy-manifest` | PrivacyManifestChecker | App targets missing or with a malformed `PrivacyInfo.xcprivacy` — opt-in by app detection, so pure SPM libraries are skipped |
| `hig-auditor` | HIGAuditor | Apple Human Interface Guidelines compliance for SwiftUI views |
<!-- /generated:checker-table-safety-security -->

### Code Hygiene

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-code-hygiene -->
| `accessibility` | AccessibilityAuditor | SwiftUI accessibility: missing labels, fixed font sizes, color-only differentiation |
| `logging` | LoggingAuditor | `print()` in production code, silent `catch` blocks, missing os.Logger usage |
| `test-quality` | TestQualityAuditor | Floating-point assertions, missing or vacuous test assertions, silent skips, ambient time, unseeded randomness in tests |
| `context` | ContextAuditor | Missing consent guards, unguarded analytics, surveillance patterns |
| `idiom` | IdiomAuditor | Non-idiomatic Swift the language has a shorter form for; `// idiom:exempt` is recorded, never silent (advisory) |
| `smells` | SmellPack | Structural smells in declarations: long parameter lists, feature envy, primitive obsession; `// smell:exempt` is recorded (advisory) |
| `duplication` | DuplicationAuditor | Token-level clone detection across files and modules (advisory) |
<!-- /generated:checker-table-code-hygiene -->

### Documentation

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-documentation -->
| `doc-lint` | DocLinter | DocC documentation build errors |
| `doc-code` | DocCodeAuditor | Fenced Swift in DocC articles must compile against the built module — the article is one program |
| `doc-run` | DocCodeAuditor | DocC articles must *run* top to bottom without trapping, not merely compile — the article is one program (opt-in) |
| `doc-claims` | DocCodeAuditor | Figures a DocC article publishes must match what that article's own program computes (opt-in) |
| `doc-comment-code` | DocCodeAuditor | Fenced Swift in `///` and `/** */` doc comments must compile against the module the comment lives in — the unit is one fence (opt-in) |
| `doc-generated` | DocGeneratedAuditor | Derived content committed as prose — rosters, registries, changelog links — must still match what it was derived from |
| `doc-coverage` | DocCoverageChecker | Undocumented public APIs, inherited documentation detection, usage-priority ranking |
<!-- /generated:checker-table-documentation -->

### Project Health

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-project-health -->
| `build` | BuildChecker | `swift build` wrapper — captures all compiler errors and warnings |
| `test` | TestRunner | `swift test` wrapper — parses Swift Testing and XCTest results; flip detector flags scheduler-dependent pass↔fail outcome changes on an unchanged package; optional stress mode re-runs `// TIMING:`-tagged tests to provoke races |
| `memory-builder` | MemoryBuilder | Claude Code project memory generation and validation |
| `status` | StatusAuditor | Drift between project docs and actual code state; supports `--fix` |
| `swift-version` | SwiftVersionChecker | swift-tools-version validation and upgrade feasibility |
| `dependency-audit` | DependencyAuditor | Package.resolved sync, branch pins, local overrides, hallucinated import detection via AST-parsed manifests |
| `submodule-audit` | SubmoduleAuditor | Git submodule pin and allowlist compliance |
| `release-readiness` | ReleaseReadinessAuditor | CHANGELOG entries, README placeholders, pending-work markers |
<!-- /generated:checker-table-project-health -->

### Specialty

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-specialty -->
| `mcp-readiness` | MCPReadinessAuditor | MCP tool schema vs. implementation cross-reference |
| `control-mapping` | ControlMapping | Integrity of the SOC 2 / ISO 27001 / HIPAA / CWE rule mapping — phantom-rule / phantom-control / superseded-catalog errors, catalog-staleness warning |
| `appintents-readiness` | AppIntentsAuditor | App Intents entity conformance, parameter wrappers, metadata protocols |
| `consistency` | ConsistencyChecker | Institutional consistency scoring via IJS pulse and telemetry |
| `xcode-build` | XcodeBuildChecker | Xcode build of a project, workspace or Swift package, and IndexStore generation (opt-in) |
<!-- /generated:checker-table-specialty -->

## CLI reference

| Flag | Description |
|------|-------------|
| `--check <name>` | Run specific checker(s) by ID, separated by spaces or commas. Use `all` for every checker. An unknown ID is an error (exit 64) |
| `--exclude <name>` | Skip checker(s) — from the default set, `--check all`, or an explicit `--check` |
| `--format <fmt>` | Output format: `terminal` (default), `json`, `sarif`, `xcode` |
| `--config <path>` | Config file path (default: `.quality-gate.yml`) |
| `--continue-on-failure` | Run all checks even if one fails |
| `--strict` | Treat warnings as failures (exit code 1): the run fails when the summary's warning count is above zero |
| `--verbose` | Show detailed progress |
| `--fix` | Apply auto-fixes for `FixableChecker` conformers |
| `--dry-run` | Preview `--fix` changes without writing (requires `--fix`) |
| `--bootstrap` | Generate initial status documents from project state |
| `--auto-build-xcode` | Drive `xcodebuild` for IndexStore when needed by unreachable checker |

## Configuration

Create `.quality-gate.yml` in your project root:

```yaml
parallelWorkers: 8

excludePatterns:
  - "**/Generated/**"
  - "**/Vendor/**"

safetyExemptions:
  - "// SAFETY:"

enabledCheckers:
  - build
  - test
  - safety
  - recursion
  - concurrency
  - pointer-escape

buildConfiguration: debug

concurrency:
  justificationKeyword: "Justification:"
  allowPreconcurrencyImports:
    - Alamofire

pointerEscape:
  allowedEscapeFunctions:
    - vDSP_fft_zip

security:
  enabledRules: []
  secretPatterns: [password, secret, apiKey, token, credential, privateKey]
  allowedHTTPHosts: [localhost, 127.0.0.1]
```

To add one opt-in checker to the default run without enabling the rest, list it under
`includedCheckers:` (the mirror of `excludedCheckers:`). For example, a package whose code is
gated `#if os(watchOS)` can build it on every run:

```yaml
includedCheckers:
  - xcode-build

xcodeBuild:
  scheme: MyPackage
  destinations:
    - "generic/platform=watchOS"
```

`xcode-build` builds a plain Swift package from its directory, with no `.xcodeproj` needed.
When it finds no workspace, project or `Package.swift`, it reports SKIPPED, not PASSED.

Per-checker configuration sections are available for `concurrency`, `pointerEscape`, `security`, `status`, `logging`, `dependencyAudit`, `releaseReadiness`, `fpSafety`, `stochasticDeterminism`, `memoryLifecycle`, `mcpReadiness`, `appIntentsReadiness`, `build`, `xcodeBuild`, `recursion`, `complexity`, `docCoverage`, `keychain-secrets`, `privacy-manifest`, and `consistency`.

Severity overrides let you downgrade or upgrade any rule:

```yaml
overrides:
  - ruleId: "force-unwrap"
    severity: warning
  - ruleId: "security.insecure-transport"
    severity: error
```

## Exemptions

Suppress specific warnings with inline comments:

```swift
// SAFETY: Guaranteed non-nil by UIKit lifecycle
let view = optionalView!

// SECURITY: Test fixture, not a real credential
let testKey = "sk-test-only"

// Justification: Sendable compliance verified via code review
struct LegacyWrapper: @unchecked Sendable { ... }
```

## CI integration

### GitHub Actions

```yaml
- name: Build Quality Gate
  run: swift build -c release

- name: Run Quality Gate
  run: .build/release/quality-gate --format sarif > results.sarif

- name: Upload SARIF
  uses: github/codeql-action/upload-sarif@v2
  with:
    sarif_file: results.sarif
```

### Pre-push hook

```bash
#!/bin/bash
quality-gate --check build --check safety
```

### Reusable workflow

A reusable GitHub Actions workflow is provided at `.github/workflows/quality-gate-reusable.yml` for use across multiple repositories.

## Documentation

Every checker module includes a DocC catalog with detailed guides. Build the documentation locally:

```bash
swift package generate-documentation --target QualityGateCore
swift package generate-documentation --target SafetyAuditor
swift package generate-documentation --target ConcurrencyAuditor
# ... any module name from the checker table above
```

For the full tutorial — design philosophy, architecture walkthrough, and integration patterns — see the **[Guide](GUIDE.md)**.

## Architecture

```
quality-gate-swift/
├── Sources/
│   ├── QualityGateCore/       # Protocol, models, reporters, configuration
│   ├── QualityGateTestKit/    # Test helpers for writing checker tests
│   ├── QualityGateCLI/        # Umbrella CLI entry point
│   ├── IndexStoreInfra/       # Shared IndexStoreDB infrastructure
│   ├── IJS*/                  # Institutional Judgment System modules
│   └── <one module per checker, each with its own DocC catalogue>
├── Tests/                     # One test target per checker module
├── Plugins/
│   └── QualityGatePlugin/     # SPM command plugin
└── .github/workflows/         # CI, quality gate, security staleness
```

Counts live in the generated block above rather than here: a number written into prose is a number nobody regenerates.

Each checker is an independent module — depend on only what you need:

```swift
.target(
    name: "MyTool",
    dependencies: [
        .product(name: "SafetyAuditor", package: "quality-gate-swift"),
        .product(name: "ConcurrencyAuditor", package: "quality-gate-swift"),
    ]
)
```

## Honest limits

**Rung 3 has the least evidence here.** On another package `doc-claims` caught a bond documented at `$1,043.30` that prices at `$1,043.76` — the stale figure was exactly the annual-coupon price, so the documentation had preserved a payment-frequency bug the code had already fixed. But this repository has zero adoption of the claim convention (`// Result:` / `// Output:`), so `doc-claims` reports **0 claims across 0 articles** here. It is real code with a real find, measured elsewhere.

**`doc-claims` will never support `--fix`.** Not deferred — prohibited. An autofixer that rewrites a documented number to match the program can never fail, and therefore never means anything. The pressure when this checker is red at 5pm is precisely to edit the comment until it goes green, and a tool that automates that pressure is worse than no tool.

**It is slower than a linter.** Some checkers need a full build; `unreachable` needs an index store.

**Some checkers need project context you may not have.** `status` reads a project plan from a configured path and reports unavailable rather than passing when it cannot find one.

**One checker is weaker on Linux than on macOS.** `unreachable`'s cross-module pass does not
yet flag an unreferenced symbol in an *executable* target there: the same symbol is still
caught by the intra-file rule, so it is not missed, but it arrives as a warning about one file
rather than as "unreachable from any entry point". Library targets are unaffected. It is
listed here rather than left for a reader to discover, because a checker that is quieter on
one platform is exactly the kind of thing this tool exists to make visible.

**Linux is newer than the rest of this.** It builds, the suite runs, and the checkers work —
but macOS has years of use behind it and Linux has days. The Linux job is
[`linux.yml`](.github/workflows/linux.yml); if something misfires there specifically, say so
in the issue, because the two platforms have already diverged in ways neither the compiler nor
the test suite caught on its own: `appendingPathComponent(_:)` consults the filesystem on
Linux and not on Darwin, and a checker that could not find its index store reported **passed**
rather than reporting that it had not looked.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

Issues and pull requests welcome — especially false-positive reports, which are what the calibration data is built from.

1. Fork the repository
2. Create a feature branch
3. Ensure all checks pass: `quality-gate --check all --continue-on-failure`
4. Submit a pull request
