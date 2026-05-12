# Design Proposal: Precision Filters Batch (FP-Safety, Dependency Audit, Release Readiness)

## 1. Problem

Three categories of defect can ship through the current quality gate undetected:

1. **Floating-point fragility in production code.** TestQualityAuditor flags `==` on `Double` in tests, but production code using `==`/`!=` on floating-point types or dividing without a zero guard is unchecked. Financial and scientific code is particularly vulnerable.

2. **Vulnerable or stale dependencies.** SPM has no built-in vulnerability scanning. A yanked or CVE-affected transitive dependency can sit in `Package.resolved` indefinitely with no alert.

3. **Release hygiene gaps.** A release build can ship with TODO/FIXME markers in README, no CHANGELOG entry for the current version, or stale placeholder text — none of which any current checker flags.

These are distinct failure modes but share a common trait: they're simple to detect mechanically with high signal-to-noise ratios.

## 2. Objective

Add three new QualityChecker modules that catch these classes of defect at the quality gate:

| Checker ID | What it catches |
|---|---|
| `fp-safety` | Floating-point equality comparisons and unguarded division in production code |
| `dependency-audit` | Outdated, yanked, or known-vulnerable SPM dependencies |
| `release-readiness` | Missing CHANGELOG entries, TODO/FIXME in README, placeholder text |

## 3. Proposed Checkers

### 3.1 — FloatingPointSafetyAuditor (`fp-safety`)

**Approach:** SwiftSyntax AST visitor that walks `Sources/` (excluding test files).

**Rules:**

| Rule ID | Flags | Severity |
|---|---|---|
| `fp-equality` | `==` or `!=` between two `Double`, `Float`, `CGFloat`, or `Decimal` operands | warning |
| `fp-division-unguarded` | Division (`/`, `/=`) where the divisor is not preceded by a zero guard within the enclosing scope | warning |
| `fp-literal-comparison` | Exempt: comparison to literal `0.0`, `.zero`, `.nan`, `.infinity` | — (allowlisted) |

**False-positive mitigation:**
- Comparisons to literals (`0.0`, `.zero`, `.nan`, `.infinity`, `.greatestFiniteMagnitude`) are exempt
- `Equatable` conformance synthesis (e.g., `struct` with `Double` fields) is exempt — flag only explicit `==`/`!=` operator calls
- Per-file `// fp-safety:disable` comment to suppress for files with legitimate exact comparison (e.g., lookup tables)
- Configuration allowlist in `.quality-gate.yml`:

```yaml
fp-safety:
  allowedFiles: []
  checkDivisionGuards: true
```

**SwiftSyntax pattern:** Subclass `SyntaxVisitor`. Override `visit(InfixOperatorExprSyntax)` to check operator token (`==`, `!=`, `/`, `/=`) and inspect operand types. Type inference from SwiftSyntax alone is limited — use heuristics: variable names ending in common FP suffixes, explicit type annotations in scope, and function return types.

**Known limitation:** Without full type information (which requires the compiler's type checker, not just SwiftSyntax), some comparisons will be missed or falsely flagged. Start with explicit type annotations and well-known patterns; iterate based on false-positive rates.

### 3.2 — DependencyAuditor (`dependency-audit`)

**Approach:** Shell-based checker (no SwiftSyntax needed). Parses `Package.resolved` and `Package.swift`.

**Rules:**

| Rule ID | Flags | Severity |
|---|---|---|
| `dep-outdated` | Package pinned to a version more than 2 major versions behind the latest tag (configurable) | warning |
| `dep-unresolved` | `Package.resolved` missing or out of sync with `Package.swift` | error |
| `dep-branch-pin` | Dependency pinned to a branch instead of a version tag | warning |
| `dep-local-override` | `swift package edit` overrides active (`.swiftpm/` state) | warning |

**Implementation:**
1. Parse `Package.resolved` (JSON v2/v3 format) to get pinned versions
2. Parse `Package.swift` to get declared dependency URLs and version requirements
3. For `dep-outdated`: shell out to `git ls-remote --tags <url>` to get latest tags (with configurable timeout and offline fallback)
4. For `dep-unresolved`: compare `Package.swift` dependency list against `Package.resolved` pins
5. For `dep-branch-pin`: check `Package.resolved` for `branch` revision type
6. For `dep-local-override`: check for `.swiftpm/xcode/package.xcworkspace/xcshareddata/swiftpm/Package.resolved` edits

**Configuration:**
```yaml
dependency-audit:
  maxMajorVersionsBehind: 2
  allowBranchPins: []
  offlineMode: false
```

**Trade-off:** `dep-outdated` requires network access to check latest tags. Default to `warning` status (not error) so offline builds degrade gracefully. Add `offlineMode: true` config to skip network checks entirely.

### 3.3 — ReleaseReadinessAuditor (`release-readiness`)

**Approach:** File-based checker (no SwiftSyntax needed). Reads README, CHANGELOG, and Package.swift.

**Rules:**

| Rule ID | Flags | Severity |
|---|---|---|
| `release-changelog` | No entry in CHANGELOG.md matching the version in `CommandConfiguration.version` or git tag | warning |
| `release-todo-readme` | README.md contains `TODO`, `FIXME`, `HACK`, `XXX`, or `PLACEHOLDER` | warning |
| `release-todo-sources` | Source files contain `TODO` or `FIXME` without an associated issue reference (e.g., `// TODO(#123)`) | warning |

**Implementation:**
1. Extract current version from `CommandConfiguration.version` in the CLI entry point, or from the latest git tag matching `v*` / `*.*.*`
2. Parse CHANGELOG.md for a heading or line containing that version string
3. Scan README.md for placeholder markers (case-insensitive regex)
4. Optionally scan `Sources/` for unlinked TODOs

**Configuration:**
```yaml
release-readiness:
  changelogPath: "CHANGELOG.md"
  readmePath: "README.md"
  requireIssueReference: false
  additionalMarkers: []
```

**Scoping:** This checker is most valuable as a release gate. Default to `warning` severity so it doesn't block normal development. Use `--strict` at release time to promote to failure.

## 4. Implementation Plan

| # | Step | Effort | Dependencies |
|---|---|---|---|
| 1 | Create `FloatingPointSafetyAuditor` module + tests (RED/GREEN) | Medium | SwiftSyntax |
| 2 | Create `DependencyAuditor` module + tests (RED/GREEN) | Small | None (shell + JSON parsing) |
| 3 | Create `ReleaseReadinessAuditor` module + tests (RED/GREEN) | Small | None (file reading + regex) |
| 4 | Add Configuration extensions for all three | Small | QualityGateCore |
| 5 | Register in `allCheckers` array in QualityGateCLI | Trivial | Steps 1-3 |
| 6 | Add DocC catalogs (root + guide) per process requirement | Small | Steps 1-3 |
| 7 | Quality gate self-test passes with new checkers | — | Steps 1-6 |

**Recommended order:** 2 → 3 → 1 (dependency audit and release readiness are simpler, build confidence; FP-safety is the most complex due to AST walking and type heuristics).

## 5. Success Criteria

- `quality-gate --check fp-safety` flags `x == y` where both are `Double` in production code, but not in test files or with literal comparisons
- `quality-gate --check dependency-audit` reports outdated/branch-pinned dependencies with graceful offline fallback
- `quality-gate --check release-readiness` catches missing CHANGELOG entries and README placeholders
- All three pass quality-gate self-audit (zero warnings on quality-gate-swift itself)
- False-positive rate < 5% on quality-gate-swift codebase (measured during implementation)

## 6. Open Questions

1. **Should `fp-safety` run on test files too?** TestQualityAuditor already covers the `==` case in tests. Running both creates duplicate diagnostics. Recommendation: `fp-safety` excludes `Tests/` by default.
2. **Should `dependency-audit` check transitive dependencies?** `Package.resolved` includes them, but flagging a transitive dep the user can't directly control may be noise. Recommendation: direct dependencies only by default, `includeTransitive: true` as config option.
3. **Should `release-readiness` be excluded from `--check all` default runs?** It's only meaningful at release time. Recommendation: include it but default all rules to `warning` severity — `--strict` promotes at release.

---

**Date:** 2026-04-29
**Author:** Justin Purnell + Claude Opus 4.6
