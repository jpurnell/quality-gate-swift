# Session Summary: C-Style Format String Detection

| Date | Phase | Status |
| :--- | :--- | :--- |
| 2026-04-07 | SafetyAuditor extension | COMPLETED |

## 1. Core Objective

Add mechanical enforcement for the existing "no `String(format:)`" rule
(`development-guidelines/00_CORE_RULES/01_CODING_RULES.md` §3.7), motivated by
a 2026-04-07 SIGSEGV in BioFeedbackKit's FrequencyDomain validation playground
caused by `String(format: "%s", swiftString)`. Plan:
`02_IMPLEMENTATION_PLANS/UPCOMING/StringFormatDetection.md`.

## 2. Design Decisions

- **Decision:** Extend `SafetyAuditor` rather than create a new module.
- **Rationale:** Same shape as existing forbidden-pattern checks; reuses file
  walk, exemption logic, diagnostic plumbing, CLI registration, and SARIF/JSON
  output. A separate module would duplicate all of that for one rule.
- **Alternatives Considered:** Standalone `FormatStringAuditor` module — rejected
  per the implementation plan §2.

- **Decision:** No new `Configuration` fields.
- **Rationale:** Existing `safetyExemptions` (`// SAFETY:`) and
  `excludePatterns` already cover the needed escape hatches. YAGNI on a
  per-rule disable flag until there's evidence it's needed.

- **Decision:** Severity = `.error`, ruleId = `c-style-format-string` (single
  ruleId shared by all five detected patterns).

## 3. Work Completed

### Design Proposal
- [x] Approved plan already existed in `UPCOMING/StringFormatDetection.md`

### Tests Written (RED phase)
- [x] Positive: `String(format:)` (1/multi-arg), `String(format:locale:)`,
      `String(format:locale:arguments:)`, `NSString(format:)`,
      `NSString.localizedStringWithFormat(_:_:)`
- [x] Negative: inside string literal, doc comment, multi-line string, on
      `// SAFETY:` line, `String.padding(toLength:...)`, `value.formatted()`,
      `DateFormatter.string(from:)`
- [x] Diagnostic shape: severity, ruleId, suggestedFix citation
- [x] Multi-violation count, line number accuracy
- [x] Regression fixture: BioFeedbackKit `String(format: "%s", label)` crash

### Implementation (GREEN phase)
- Files modified:
  - `Sources/SafetyAuditor/SafetyAuditor.swift` — added
    `isCStyleFormatStringCall(_:)` and `hasFormatArgument(_:)` helpers; added a
    detection branch at the top of `visit(_ FunctionCallExprSyntax)` that runs
    before the existing `DeclReferenceExpr`-only switch (so member-access
    callees like `NSString.localizedStringWithFormat` are also caught). Updated
    the type doc comment.
- Files created:
  - `Tests/SafetyAuditorTests/CStyleFormatStringDetectionTests.swift` — 19 tests.
- Files moved:
  - `development-guidelines/02_IMPLEMENTATION_PLANS/UPCOMING/StringFormatDetection.md`
    → `.../COMPLETED/StringFormatDetection.md`

### Documentation
- [x] `SafetyAuditor.swift` doc comment lists the new pattern.
- [x] `README.md` Safety Auditor Rules table updated.

## 4. Mandatory Quality Gate (Zero Tolerance)

| Requirement | Command / Tool | Status |
| :--- | :--- | :--- |
| **Zero Test Failures** | `swift test` (220 tests) | ✅ |
| **Zero Build Warnings** | `swift build` | ✅ (test run includes build) |

## 5. Project State Updates

- [x] Plan moved from `UPCOMING/` to `COMPLETED/`.
- [x] README updated.

## 6. Next Session Handover

### Immediate Starting Point

C-style format string detection is shipped. If a follow-up is desired, the plan
§10 lists future extensions (each its own ruleId, separate PR):
`withVaList`, direct `printf`/`fprintf`/`sprintf`, `CFStringCreateWithFormat`,
custom `+stringWithFormat:` overloads.

### Pending Tasks

- [ ] Verify the local copy of `00_CORE_RULES/01_CODING_RULES.md` §3.7 matches
      upstream after this lands (plan §8.4).
- [ ] Cut a quality-gate-swift release noting the new rule (no CHANGELOG file
      currently exists in the repo — defer until one is introduced or add
      release notes to the GitHub release).

### Context Loss Warning

The detection branch sits *before* the early `return .visitChildren` in
`visit(_ FunctionCallExprSyntax)`. The early return only fires for non-
`DeclReferenceExpr` callees and would otherwise skip
`NSString.localizedStringWithFormat` (a `MemberAccessExpr`). Don't move the
format-string check below that guard.

---

**AI Model Used:** Claude Opus 4.6 (1M context)
