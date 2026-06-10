# Design Proposal: ComplianceRecord Type

**Date:** 2026-06-10
**Project:** quality-gate-swift + quality-gate-types
**Status:** PROPOSED

---

## 1. Objective

**Problem:** The quality-gate system treats inline compliance annotations (`// Justification:`, `// SAFETY:`, config allowlists) identically to true violation suppressions. Both produce `DiagnosticOverride` objects, which flow into `CalibrationClassifier`, generate calibration JSON files on disk, and inflate the `totalOverrides` metric in pulse/narrative output.

This caused a phantom jump from 0 to 193 overrides in the June 2026 pulse window, with 16,481 calibration file entries across the corpus. The narrative flagged this as a "defining fact" and questioned portfolio quality — but no code quality actually changed. Every "override" was a required compliance comment that had always existed.

**Root cause:** `DiagnosticOverride` conflates two semantically different events:
1. **Compliance annotation** — A required comment proving code correctness (e.g., `// Justification: IndexStoreDB is read-only` on `@unchecked Sendable`). The auditor checks for the comment, finds it, and emits no diagnostic. The code is *compliant*.
2. **Violation suppression** — A comment that acknowledges a real violation and suppresses it (e.g., `// TEST-QUALITY: intentional exact equality` to silence `exact-double-equality`). The violation *exists* but is justified away.

Only category 2 should count as an "override" in the institutional judgment system.

**Impact:** Override metrics, anomaly detection (z-scores), calibration file volume, narrative accuracy, and the `overrideRate` field on `DailySnapshot` and `PulseStatistics` are all corrupted.

---

## 2. Proposed Architecture

### Type Changes (quality-gate-types)

**New File:**
- `Sources/QualityGateTypes/ComplianceRecord.swift`

**Modified Files:**
- `Sources/QualityGateTypes/CheckResult.swift` — add `complianceRecords` field

### Auditor Changes (quality-gate-swift)

**Modified Files — change `DiagnosticOverride` to `ComplianceRecord` for compliance-only sites:**
- `Sources/PointerEscapeAuditor/PointerEscapeAnalyzer.swift` (lines 309, 419) — config allowlist matches
- `Sources/ConcurrencyAuditor/ConcurrencyAnalyzer.swift` — `// Justification:` on `@unchecked Sendable`

**Modified Files — auditors that aggregate both types:**
- `Sources/SafetyAuditor/SafetyAuditor.swift` — pass through `complianceRecords`
- `Sources/LoggingAuditor/LoggingAuditor.swift` — pass through `complianceRecords`
- `Sources/ConcurrencyAuditor/ConcurrencyAuditor.swift` — pass through `complianceRecords`
- `Sources/TestQualityAuditor/TestQualityAuditor.swift` — remains `DiagnosticOverride` (true suppressions)
- `Sources/AccessibilityAuditor/AccessibilityAuditor.swift` — remains `DiagnosticOverride` (true suppressions)
- `Sources/HIGAuditor/*.swift` — remains `DiagnosticOverride` (true suppressions)
- `Sources/PointerEscapeAuditor/PointerEscapeAuditor.swift` — pass through `complianceRecords`

### Telemetry/Pulse Changes (quality-gate-swift)

**Modified Files:**
- `Sources/QualityGateCLI/QualityGateCLI.swift` — separate compliance records from overrides; do NOT pass compliance records to `CalibrationClassifier`
- `Sources/IJSSensor/CheckResultMetadata.swift` — add `complianceCount: Int` field (no per-record storage needed)
- `Sources/IJSSensor/DailySnapshot.swift` — add `complianceAnnotations: Int` field
- `Sources/IJSSensor/PulseStatistics.swift` — add `totalComplianceAnnotations: Int` field
- `Sources/IJSRefiner/PulseRefiner.swift` — count compliance annotations separately from overrides
- `Sources/IJSAggregator/TelemetryWriter.swift` — do NOT write calibration files for compliance records

---

## 3. API Surface

### New Type

```swift
/// A record that a compliance annotation was found and verified.
///
/// Unlike `DiagnosticOverride` (which represents a suppressed violation),
/// a `ComplianceRecord` confirms that the code meets the auditor's
/// requirements through an inline annotation. No violation occurred.
///
/// Examples:
/// - `// Justification:` on `@unchecked Sendable` (concurrency auditor)
/// - Config-allowlisted function in `withUnsafe*` block (pointer escape auditor)
/// - `// SAFETY:` on validated file operations (security visitor)
public struct ComplianceRecord: Sendable, Codable, Equatable {
    /// The rule that was checked and found compliant.
    public let ruleId: String

    /// The annotation text or config entry that proves compliance.
    public let annotation: String

    /// Source file path where the annotation was found.
    public let filePath: String?

    /// Line number of the annotation.
    public let lineNumber: Int?

    public init(
        ruleId: String,
        annotation: String,
        filePath: String? = nil,
        lineNumber: Int? = nil
    ) {
        self.ruleId = ruleId
        self.annotation = annotation
        self.filePath = filePath
        self.lineNumber = lineNumber
    }
}
```

### Modified CheckResult

```swift
public struct CheckResult: Sendable, Codable, Equatable {
    public let checkerId: String
    public let status: Status
    public let diagnostics: [Diagnostic]
    public let overrides: [DiagnosticOverride]           // True suppressions only
    public let complianceRecords: [ComplianceRecord]     // NEW
    public let duration: Duration
}
```

### Modified CheckResultMetadata

```swift
public struct CheckResultMetadata: Sendable, Codable, Equatable {
    // ... existing fields ...
    public let overrides: [OverrideRecord]       // True suppressions only
    public let complianceCount: Int              // NEW — aggregate count, not per-record
    // ...
}
```

### Classification Rule

Each auditor must decide at the emission site:

| Signal | Type | Example |
|--------|------|---------|
| Auditor finds NO violation because annotation proves correctness | `ComplianceRecord` | `@unchecked Sendable` with valid `// Justification:` |
| Config allowlist prevents a violation from being raised | `ComplianceRecord` | `PointerEscapeAnalyzer` matching `async` in allowlist |
| Auditor finds a violation but suppresses it due to comment | `DiagnosticOverride` | `// TEST-QUALITY:` suppressing `exact-double-equality` |
| Auditor finds a violation but suppresses it due to config | `DiagnosticOverride` | `.quality-gate.yml` severity override to `off` |

**Key distinction:** If the comment is *required by the auditor's own rules* for the code to be considered correct, it's compliance. If the comment *suppresses a finding the auditor would otherwise report*, it's an override.

---

## 4. MCP Schema

Not applicable — `ComplianceRecord` is an internal telemetry type, not exposed via MCP tools. The existing `ListOverridesTool` should continue to list only true `DiagnosticOverride` records.

---

## 5. Constraints & Compliance

- **Concurrency:** `ComplianceRecord` is `Sendable` (immutable value type)
- **Codable:** Required for telemetry serialization; backward-compatible via `decodeIfPresent` for `complianceRecords` field
- **Backward Compatibility:** Old telemetry files without `complianceRecords` or `complianceCount` decode cleanly with defaults of `[]` and `0`
- **No force unwraps:** All fields are value types or optionals

---

## 6. Dependencies

**Internal Dependencies:**
- `quality-gate-types` — new `ComplianceRecord` type, modified `CheckResult`
- Every auditor that currently emits `DiagnosticOverride` — audit and reclassify

**External Dependencies:** None

**Cross-Package:** `quality-gate-types` is a separate SPM package imported by `quality-gate-swift`. The type must be defined there since `CheckResult` lives there.

---

## 7. Test Strategy

**Test Categories:**

1. **Type tests** — `ComplianceRecord` Codable round-trip, Equatable
2. **Auditor classification tests** — For each auditor, verify:
   - Compliance annotations produce `ComplianceRecord`, not `DiagnosticOverride`
   - True suppressions still produce `DiagnosticOverride`
   - `CheckResult.overrides` does not contain compliance items
   - `CheckResult.complianceRecords` does not contain suppression items
3. **Calibration pipeline tests** — Verify `CalibrationClassifier` receives only `DiagnosticOverride`, never `ComplianceRecord`
4. **Pulse statistics tests** — Verify `totalOverrides` counts only true overrides; `totalComplianceAnnotations` counts only compliance records
5. **Backward compatibility tests** — Decode old telemetry JSON (no `complianceRecords` field) without error
6. **Integration test** — Run quality-gate on a project with known compliance annotations, verify override count is 0 and compliance count matches expected

**Reference Truth:**
- IconquerAI currently produces 0 true overrides but has compliance annotations in concurrency auditor results
- quality-gate-swift currently produces ~11,488 calibration files — after fix, should produce calibrations only for true suppressions

---

## 8. Migration Plan

### Phase 1: Types (quality-gate-types)
1. Add `ComplianceRecord` type
2. Add `complianceRecords: [ComplianceRecord]` to `CheckResult` with default `[]`
3. All existing code continues to compile — new field has a default

### Phase 2: Auditors (quality-gate-swift)
4. Reclassify each emission site per the classification table above
5. Update auditor return types to include both `overrides` and `complianceRecords`
6. Thread `complianceRecords` through aggregation in each auditor's `check()` method

### Phase 3: Telemetry Pipeline
7. Update `QualityGateCLI.run()` to NOT pass `complianceRecords` to `CalibrationClassifier`
8. Add `complianceCount` to `CheckResultMetadata`
9. Update `TelemetryWriter` — no calibration files for compliance records
10. Update `PulseRefiner` — count compliance annotations separately

### Phase 4: Corpus Scrub
11. Write a migration script that walks all `*_calibration_*.json` files in the corpus telemetry tree
12. For each calibration file, check if the `ruleId` + `justification` matches the `ComplianceRecord` classification rules (e.g., PointerEscapeAnalyzer allowlist entries, ConcurrencyAnalyzer `// Justification:` comments)
13. Delete calibration files that represent compliance annotations; preserve true override calibrations
14. Commit the scrubbed corpus
15. Re-run pulse generation to verify override count drops to expected value and legitimate calibration data is intact

---

## 9. Architecture Decision Review

**ADR Check:**
- [x] Reviewed `06_ARCHITECTURE_DECISIONS.md` for related decisions
- [ ] Does this supersede an existing ADR? No
- [ ] Does this amend an existing ADR? No
- [x] New ADR required? Yes

**New ADR Draft:**
- **Title:** Separate compliance annotations from violation overrides
- **Category:** architecture
- **Key decision:** Introduce `ComplianceRecord` as a distinct type from `DiagnosticOverride` so that required auditor compliance annotations (which prove code correctness) do not inflate override metrics or generate calibration events.

---

## 10. Open Questions — RESOLVED

1. **Should compliance records be stored in telemetry at all?**
   **Decision: Count only.** Store `complianceCount: Int` in metadata. Per-record detail is recoverable by re-running the gate; storing 16k+ individual records per window is wasteful.

2. **Should the existing calibration files be cleaned up?**
   **Decision: Scrub in place.** Write a migration script that walks existing calibration JSON files, identifies compliance-only entries (matching the `ComplianceRecord` classification rules), and deletes them. This preserves legitimate calibration data (true overrides) while removing the phantom entries. Preferable to bulk-delete (which loses real calibrations) or waiting 30 days (which leaves the metrics corrupted for a month).

3. **Which auditor sites are ambiguous?**
   **Decision: Default to override.** When classification is unclear, keep the entry as `DiagnosticOverride`. Only reclassify to `ComplianceRecord` when clearly the annotation is the auditor's own required compliance mechanism (e.g., `// Justification:` on `@unchecked Sendable`, config allowlist match in PointerEscapeAnalyzer). Conservatively treating ambiguous cases as overrides means we can relax later without retroactively inflating metrics.

---

## 11. Documentation Strategy

**Documentation Type:** API Docs Only

**Complexity Threshold Check:**
- Does it combine 3+ APIs? No
- Does explanation require 50+ lines? No
- Does it need theory/background context? No

DocC comments on `ComplianceRecord` and the modified `CheckResult` field are sufficient.
