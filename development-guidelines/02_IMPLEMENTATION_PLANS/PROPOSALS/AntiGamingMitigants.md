# Proposal: Anti-Gaming Mitigants

## Context

External review identified five gaming vectors in the Institutional Judgment System.
Current mitigants are mostly detective (corpus analysis, clustering). This proposal
adds preventive and enforcement-grade controls.

## M1: Justification Quality Enforcement

**Problem**: `// Justification: safe` passes the gate. Pure string containment check.

**Implementation**: Add quality rules to the existing `ConcurrencyAnalyzer.overrideIfJustified()`:

1. **Minimum substance**: Justification must be >= 8 words after the keyword. Reject
   single-word or empty justifications.
2. **Denylist**: Reject known-generic phrases: `"safe"`, `"needed"`, `"legacy"`,
   `"works fine"`, `"temporary"`, `"will fix later"`, `"not a problem"`.
3. **Duplicate detection**: Track justification text across the file. Flag identical
   justifications used more than twice — copy-paste signal.
4. **Specificity heuristic**: Justification should reference at least one of: a type name,
   a protocol, a framework, or a concurrency construct. Not enforced as error — emitted
   as warning for pulse visibility.

**Rule IDs**: `justification.too-short`, `justification.generic`, `justification.duplicate`

**Severity**: `error` for too-short and generic (blocks gate), `warning` for duplicate
(visible in pulse).

**Module**: `ConcurrencyAuditor` (extends existing `overrideIfJustified`), plus a new
shared `JustificationValidator` in `QualityGateCore` so other auditors can reuse it.

## M2: Scope-Aware Safety Checks

**Problem**: AccessibilityAuditor's `reduceMotion` check uses a 10-line radius. Developers
can move the animation call away from the check to avoid detection.

**Implementation**: Replace line-radius search with scope-aware analysis:

1. When a `withAnimation` or `.animation()` is found, identify the enclosing scope
   (function body, computed property, or View `body`).
2. Search the entire enclosing scope for `reduceMotion` / `accessibilityReduceMotion`,
   not just ±10 lines.
3. Keep the radius check as a fast-path optimization — if found within radius, skip
   the more expensive scope walk.

**Module**: `AccessibilityAuditor` — refactor `hasNearbyReduceMotionCheck` to
`hasReduceMotionCheck` with scope fallback.

## M3: QG_SKIP with Accountability

**Problem**: QG_SKIP doesn't exist yet. Building it without accountability would create
the exact escape hatch the criticism warns about.

**Implementation**: Add `QG_SKIP` as a first-class, tracked mechanism:

1. **Activation**: `QG_SKIP=<issue-url>` environment variable. Requires a URL or
   issue reference — bare `QG_SKIP=1` is rejected.
2. **Corpus recording**: Every skip is recorded in the corpus as a `SkipRecord` with
   timestamp, author, issue reference, and project ID.
3. **TTL enforcement**: The ConsistencyChecker tracks skip age. Skips older than 48
   hours without a subsequent clean gate run produce a `consistency-finding` with
   `matchType: .unaddressedSkip`.
4. **Rate limiting in pulse**: PulseRefiner counts skips per project per window. More
   than 2 skips per project per week triggers a `StatisticalAnomaly`.
5. **Pulse visibility**: Skip count and staleness appear in the weekly narrative context.

**Modules**: `QualityGateCLI` (skip activation + validation), `IJSSensor` (SkipRecord type),
`IJSAggregator` (corpus write), `ConsistencyChecker` (TTL), `IJSRefiner` (rate limiting).

## M4: Proposal Staleness Tracker

**Problem**: Teams propose policy changes to satisfy the system but never implement them.

**Implementation**: Track proposal lifecycle in the PulseRefiner:

1. When `proposedPolicyUpdates` appear in a pulse, record them with their first-seen
   week label.
2. Each subsequent pulse checks if the proposal still appears AND the corresponding
   violation cluster hasn't resolved.
3. After 3 consecutive pulses (~3 weeks) with an unresolved proposal, emit it as a
   `ViolationCluster` with `dominantRootCause: "stale-proposal"`.
4. After 6 pulses (~6 weeks), escalate to a `proposedPolicyUpdate` recommending
   either implementation or withdrawal.

**Storage**: Add `proposalFirstSeen: [String: String]` to pulse JSON (maps proposal
text hash to first-seen week label).

**Module**: `IJSRefiner` (PulseRefiner), `IJSCore` (InstitutionalPulse model).

## M5: Override-to-Resolution Ratio

**Problem**: Consistency score improves when overrides are added, even if the underlying
code isn't fixed. Teams can "suppress" instead of "resolve."

**Implementation**: Add resolution tracking to ConsistencyScorer:

1. For each violation cluster, compare: did the occurrence count drop because of
   code fixes (fewer diagnostics) or because of new overrides (more DiagnosticOverrides)?
2. Compute `resolutionRate = codeFixCount / (codeFixCount + newOverrideCount)` per cluster.
3. Clusters with `resolutionRate < 0.5` (majority overrides) get flagged as
   `consistency-finding` with `matchType: .suppressionPattern`.
4. This finding produces a deduction in the consistency score, counteracting the
   "improvement" from overrides.

**Module**: `IJSPolicyDiscovery` (ConsistencyScorer), `IJSRefiner` (cluster resolution
tracking).

## Implementation Order

| # | Mitigant | Complexity | Dependencies |
|---|----------|-----------|--------------|
| M1 | Justification Quality | Medium | None — extends existing auditor |
| M2 | Scope-Aware Checks | Medium | None — refactors existing auditor |
| M3 | QG_SKIP Accountability | High | Touches 5 modules |
| M4 | Proposal Staleness | Medium | PulseRefiner + model change |
| M5 | Override-to-Resolution | Medium | ConsistencyScorer + PulseRefiner |

M1 and M2 are independent and can be implemented in parallel.
M3 is the largest but most impactful — implement after M1/M2.
M4 and M5 both touch the pulse pipeline — implement sequentially.
