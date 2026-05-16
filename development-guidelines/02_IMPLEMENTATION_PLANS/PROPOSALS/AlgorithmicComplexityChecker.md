# Algorithmic Complexity Checker

**Date:** 2026-05-16
**Status:** Approved
**Context:** Advisory-only checker that measures cognitive complexity and estimates Big-O per function, then feeds structured metrics into the IJS corpus for trend analysis and institutional pattern detection. Unlike existing quality-gate auditors, this checker never fails a build — it produces telemetry that becomes actionable through the Pulse refiner over time.

---

## The Problem, Concretely

A project grows over months. No single commit introduces "bad" complexity — each change is locally reasonable. But aggregate complexity drifts upward. Developers don't notice because:

1. **No per-function baseline exists.** A function at cognitive complexity 22 might have been 8 three months ago, but nobody tracked it.
2. **Big-O problems hide in call composition.** A function calls `Array.contains` inside `filter` — each is fine alone, but together it's O(n²). The developer sees two simple operations, not their product.
3. **Recurring anti-patterns aren't surfaced.** The same `contains-in-loop` pattern appears across 7 modules, but each instance was reviewed in isolation.

The IJS Pulse refiner already detects drift in pass rates, failure rates, and override rates. Complexity is the missing metric — the one that predicts future problems before they manifest as bugs or performance issues.

---

## Design Principles

1. **Never blocks.** This checker produces metrics, not diagnostics. A function at O(n³) compiles and ships.
2. **Transparent estimation.** Every Big-O estimate includes its basis (which patterns drove it) and confidence level. No black boxes.
3. **Institutional value over individual value.** A single complexity report is mildly interesting. Complexity trends across weeks of Pulse data reveal institutional patterns worth acting on.
4. **Pattern detection over proof.** Static Big-O estimation cannot be exact. The checker identifies *patterns* (nested loops, known-cost stdlib calls, call-graph amplification) and assigns estimated classes with explicit confidence.

---

## Architecture

### Module: `ComplexityAnalyzer`

A new SPM target depending on `SwiftSyntax` and `QualityGateCore`.

```
ComplexityAnalyzer/
├── CognitiveComplexityVisitor.swift    // AST visitor, deterministic scoring
├── BigOEstimator.swift                 // Pattern-based time complexity estimation
├── PatternDetector.swift               // Known anti-pattern recognition
├── ComplexityReport.swift              // Per-function and aggregate output model
├── CallGraphAmplifier.swift            // Cross-function complexity composition
└── ComplexityTelemetryEmitter.swift    // Formats output for IJS corpus ingestion
```

### Data Flow

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────────┐
│  Swift source   │────▶│ ComplexityAnalyzer│────▶│  ComplexityReport   │
│  (.swift files) │     │  (SwiftSyntax)   │     │  (structured JSON)  │
└─────────────────┘     └──────────────────┘     └─────────┬───────────┘
                                                            │
                              ┌──────────────────────────────┤
                              ▼                              ▼
                   ┌─────────────────┐           ┌────────────────────┐
                   │  Console Report │           │  IJS Corpus Push   │
                   │  (human-readable│           │  (telemetry JSON)  │
                   │   advisory)     │           │                    │
                   └─────────────────┘           └─────────┬──────────┘
                                                           │
                                                           ▼
                                                ┌────────────────────┐
                                                │  PulseRefiner      │
                                                │  (trend analysis,  │
                                                │   drift detection, │
                                                │   pattern clusters)│
                                                └────────────────────┘
```

---

## Structured Data Model

### Per-Function Record

```swift
struct FunctionComplexityRecord: Codable, Sendable {
    let functionName: String
    let moduleName: String
    let filePath: String
    let lineRange: ClosedRange<Int>
    
    // Cognitive complexity (deterministic)
    let cognitiveComplexity: Int
    let cognitiveBreakdown: [CognitiveIncrement]
    
    // Big-O estimation (heuristic)
    let estimatedTimeComplexity: String       // "O(1)", "O(n)", "O(n²)", etc.
    let complexityBasis: [ComplexityBasis]    // What drove the estimate
    let confidence: EstimationConfidence      // .low, .medium, .high
    
    // Anti-patterns detected
    let detectedPatterns: [ComplexityPattern]
}
```

### Supporting Types

```swift
struct CognitiveIncrement: Codable, Sendable {
    let node: String              // "if", "for", "guard…else", "&&"
    let line: Int
    let baseIncrement: Int        // +1 for flow break
    let nestingIncrement: Int     // +N for nesting depth
}

enum ComplexityBasis: Codable, Sendable {
    case loopNesting(depth: Int)
    case stdlibOperation(name: String, cost: String)
    case recursion(type: RecursionType)
    case callGraphAmplification(callee: String, calleeCost: String)
}

enum RecursionType: String, Codable, Sendable {
    case linear          // f(n-1) — O(n)
    case divideConquer   // f(n/2) + f(n/2) — O(n log n)
    case branching       // f(n-1) + f(n-1) — O(2^n)
    case tail            // optimizable — O(n) space-wise
}

enum EstimationConfidence: String, Codable, Sendable {
    case high    // Single loop or no loops, known stdlib ops only
    case medium  // Nested loops with clear bounds, some unknowns
    case low     // Recursion, dynamic dispatch, unknown callees
}
```

### Anti-Pattern Types

```swift
enum ComplexityPattern: Codable, Sendable {
    case containsInFilter(collection: String, line: Int)
    case nestedLoopSameCollection(collection: String, outerLine: Int, innerLine: Int)
    case repeatedLinearSearch(collection: String, count: Int)
    case sortInLoop(line: Int)
    case quadraticStringConcat(line: Int)
    case unboundedRecursion(functionName: String, line: Int)
}
```

### Aggregate Report (per gate run)

```swift
struct ComplexityReport: Codable, Sendable {
    let projectID: String
    let timestamp: Date
    let moduleReports: [ModuleComplexityReport]
    let summary: ComplexitySummary
}

struct ModuleComplexityReport: Codable, Sendable {
    let moduleName: String
    let functions: [FunctionComplexityRecord]
    let moduleMedianCognitive: Int
    let moduleMaxCognitive: Int
    let functionsAboveThreshold: Int       // configurable threshold
    let dominantBigO: String               // most common estimated class
    let patternCounts: [String: Int]       // pattern type → occurrence count
}

struct ComplexitySummary: Codable, Sendable {
    let totalFunctions: Int
    let medianCognitiveComplexity: Int
    let p90CognitiveComplexity: Int
    let maxCognitiveComplexity: Int
    let complexityDistribution: [String: Int]  // "O(1)": 45, "O(n)": 30, ...
    let totalPatternsDetected: Int
    let patternBreakdown: [String: Int]
    let hotspots: [FunctionComplexityRecord]   // top N most complex
}
```

---

## IJS Corpus Integration

### Telemetry Emission

The complexity checker emits a `ComplexityReport` as a companion artifact alongside existing `CheckResultMetadata`. It follows the same corpus path convention:

```
telemetry/<projectID>/YYYY-MM-DD/HHmmss_complexity.json
```

This is a new artifact type — it doesn't replace or modify `metadata.json` or `calibration_*.json`. It coexists in the same daily directory.

### Pulse Refiner Extension

The PulseRefiner gains a new analysis dimension in `PulseStatistics`:

```swift
struct ComplexityTrend: Codable, Sendable {
    let metricName: String               // "medianCognitive", "p90Cognitive", "patternCount"
    let trend: TrendAnalysis             // existing trend model (mean, stdDev, slope, validity)
    let topDriftingModules: [String]     // modules whose complexity increased most
    let emergingPatterns: [String]       // anti-patterns appearing for the first time
    let resolvedPatterns: [String]       // anti-patterns that disappeared
}
```

### DailySnapshot Extension

```swift
// Added fields to DailySnapshot (or a parallel ComplexitySnapshot)
struct ComplexitySnapshot: Codable, Sendable {
    let date: String
    let scope: String
    let medianCognitive: Int
    let p90Cognitive: Int
    let maxCognitive: Int
    let totalPatterns: Int
    let functionsAboveThreshold: Int
    let dominantBigO: String
}
```

### Violation Cluster Integration

Recurring anti-patterns become `ViolationCluster` entries in the Pulse:

```
ViolationCluster:
  ruleId: "complexity.contains-in-filter"
  occurrenceCount: 7
  affectedProjectCount: 1
  dominantRootCause: "collection-type-mismatch"
  isRecurring: true
```

This means the PolicyDiscoveryAuditor can surface consistency findings like: *"contains-in-filter has appeared in 7 functions across the last 3 weeks — consider adding a Set-conversion guideline to your coding rules."*

### Feedback Loop to Development Guidelines

When the Pulse identifies a complexity pattern cluster that persists across multiple weeks:

1. The Pulse's `proposedPolicyUpdates` can suggest a new coding rule
2. The advisory finding surfaces in the consistency report
3. The team decides whether to codify it (add to `01_CODING_RULES.md`) or accept it

This is the mechanism by which complexity *observations* become institutional *practice*.

---

## Implementation Tiers

### Tier 1: Per-Function Cognitive Complexity (MVP)

- `CognitiveComplexityVisitor` — SwiftSyntax `SyntaxVisitor` that walks function bodies
- Scoring algorithm per the reference in `07_LIBRARY/COMPLEXITY_SCORING.md`
- Produces `FunctionComplexityRecord` with cognitive scores only
- Console output: ranked list of functions above threshold
- Corpus output: `ComplexityReport` with cognitive data populated

**Effort:** ~2-3 sessions. Well-understood algorithm, straightforward AST walk.

### Tier 2: Pattern Detection + Big-O Estimation

- `PatternDetector` — recognizes known anti-patterns via AST pattern matching
- `BigOEstimator` — loop depth analysis, stdlib cost lookup table, recursion classification
- Populates `estimatedTimeComplexity`, `complexityBasis`, `confidence`, `detectedPatterns`
- Console output: flagged anti-patterns with explanations and suggested fixes

**Effort:** ~3-4 sessions. Requires building a stdlib cost table and recursion analyzer.

### Tier 3: Call-Graph Amplification

- `CallGraphAmplifier` — uses function-level complexity data to detect cross-function compounding
- If function A (O(n)) is called inside a loop in function B, B's effective complexity includes that
- Requires a call graph — either built from SwiftSyntax (intra-module) or from SourceKit index data
- Populates `callGraphAmplification` basis entries

**Effort:** ~4-5 sessions. Call graph construction is the hard part; amplification logic is straightforward once you have it.

### Tier 4: Pulse Integration + Trend Analysis

- Extend `PulseRefiner` to ingest `ComplexityReport` artifacts
- Compute `ComplexityTrend` and `ComplexitySnapshot` time series
- Detect drift: "median cognitive complexity increased 30% over 4 weeks"
- Cluster anti-patterns into `ViolationCluster` entries
- Surface consistency findings for recurring patterns

**Effort:** ~2-3 sessions. Leverages existing trend/anomaly infrastructure in IJS.

---

## Configuration

```yaml
# .quality-gate.yml
complexity:
  enabled: true
  cognitiveThreshold: 15          # default; flag functions above this (advisory only)
  reportTopN: 10                  # number of hotspots in summary
  moduleThresholds:               # per-module overrides
    Parser: 25                    # parsers are inherently branchy
    StateMachine: 20
    Utilities: 10                 # utilities should stay simple
  patterns:
    containsInFilter: true
    nestedLoopSameCollection: true
    repeatedLinearSearch: true
    sortInLoop: true
    quadraticStringConcat: true
    unboundedRecursion: true
  callGraph:
    enabled: false                # Tier 3, off by default
    maxDepth: 3                   # how many call levels to trace
  corpus:
    emit: true                    # push ComplexityReport to corpus
    crossProject: true            # surface patterns across all projects in corpus
```

---

## CLI Interface

```bash
# Run complexity analysis (advisory, never fails)
quality-gate --check complexity

# Run as part of full suite (included in 'all' but never blocks)
quality-gate --check all --strict    # complexity reports but doesn't affect exit code

# Standalone analysis with detailed output
quality-gate --check complexity --verbose

# Show only functions above threshold
quality-gate --check complexity --threshold 20
```

---

## What This Does NOT Do

- **Does not fail builds.** Ever. Not even with `--strict`.
- **Does not prescribe refactoring.** It surfaces patterns; humans decide what to do.
- **Does not claim exact Big-O.** Estimates are transparent about their basis and confidence.
- **Does not replace profiling.** Static complexity estimation identifies *potential* bottlenecks. Runtime profiling confirms them.
- **Does not judge library code.** Only analyzes project source, not dependencies.

---

## Success Criteria

1. A developer can run `quality-gate --check complexity` and get a useful per-function report in under 5 seconds for a typical project.
2. After 4+ weeks of corpus data, the Pulse surfaces meaningful complexity trends (drift up/down, emerging patterns).
3. At least one recurring anti-pattern gets promoted to a coding rule within the first quarter of use, demonstrating the feedback loop works.
4. The checker's own code scores below cognitive complexity 15 for every function (eating our own cooking).

---

## Resolved Design Decisions

1. **Per-module thresholds:** Yes. Cognitive thresholds are configurable per-module in `.quality-gate.yml`. Parsers and state machines legitimately have higher inherent complexity than utility functions — the checker should be responsive to the functionality of each module rather than applying a single global number.

2. **No historical backfill.** Trends build organically from the first run forward. Retroactive analysis across past commits is a large lift with diminishing returns for young projects. The corpus accumulates naturally; 4-6 weeks of data produces usable baselines.

3. **Cross-project pattern detection:** Yes. When the corpus spans multiple projects, the Pulse surfaces patterns that appear across repos (e.g., "contains-in-filter is endemic across 4 projects"). This is one of the strongest institutional signals — it indicates a systemic gap in team knowledge rather than a one-off mistake.

4. **Tiered stdlib cost table:**

   **Built-in core table** (~50-80 operations): Swift stdlib and Foundation operations whose algorithmic guarantees are documented and stable. Ships as a hardcoded dictionary in the module. Apple doesn't change these between Swift versions, so maintenance burden is near zero.

   **Project-extensible overlay** (configurable file): Projects declare costs for their own internal functions or third-party library calls:

   ```yaml
   # .quality-gate-complexity.yml
   knownCosts:
     - pattern: "DatabaseClient.fetch*"
       cost: "O(n)"
       note: "network-bound, linear in result set"
     - pattern: "Cache.lookup"
       cost: "O(1)"
       note: "hash-based"
   ```

   **Unknown = low confidence, not wrong.** Unclassified calls drop the function's estimation confidence to `low` without guessing. Over time, the Pulse surfaces which unclassified calls appear most frequently — naturally prompting someone to add them to the overlay. The corpus makes its own blind spots visible through the advisory channel, making the maintenance question self-resolving.
