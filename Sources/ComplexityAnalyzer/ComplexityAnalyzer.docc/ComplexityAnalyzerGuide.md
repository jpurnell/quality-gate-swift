# ComplexityAnalyzer Guide

A rule-by-rule walkthrough, with the shape that triggers each one and the shape that doesn't.

## Why this analyzer exists

Reviewers are good at spotting a function that is *long*. They are much worse at spotting a
function that is *quadratic*, because the cost usually isn't visible at the call site — it's in
a standard library operation with a known cost, or in a callee two modules away.

The analyzer reports rather than blocks. Every rule below emits a note, except
`complexity.cross-module-amplification`, which emits a warning. Nothing here fails a gate.

## Rule walkthrough

### `complexity.cognitive-threshold`

A function whose cognitive complexity exceeds the threshold (default 15). Cognitive complexity
adds +1 per break in linear flow and a further +1 per level of nesting, so depth is punished
harder than length — which matches how the code actually reads.

```swift
struct Threshold {
    // scores high: each level of nesting adds to every branch inside it
    func classify(_ rows: [[Int]], limit: Int) -> Int {
        var total = 0
        for row in rows {
            for value in row {
                if value > limit {
                    if value % 2 == 0 {
                        total += value
                    } else {
                        total -= value
                    }
                }
            }
        }
        return total
    }

    // scores low: the same work, with the depth flattened out
    func classifyFlat(_ rows: [[Int]], limit: Int) -> Int {
        rows.flatMap { $0 }
            .filter { $0 > limit }
            .reduce(0) { $0 + ($1 % 2 == 0 ? $1 : -$1) }
    }
}
```

Raise the threshold per module with `moduleThresholds` when a module is legitimately dense —
a parser or a state machine will score higher than a view model and that is not a defect.

### `complexity.contains-in-filter`

A linear search inside a filter. Each element of the outer collection scans the inner one, so
the pair is quadratic even though neither line looks expensive.

```swift
struct ContainsInFilter {
    // flagged -- O(n * m)
    func slow(_ items: [Int], excluded: [Int]) -> [Int] {
        items.filter { !excluded.contains($0) }
    }

    // accepted -- hashing the inner collection first makes the lookup constant
    func fast(_ items: [Int], excluded: [Int]) -> [Int] {
        let lookup = Set(excluded)
        return items.filter { !lookup.contains($0) }
    }
}
```

This is the single most common finding in real codebases, and usually the cheapest to fix.

### `complexity.nested-loop-same-collection`

Two loops over the same collection, one inside the other — an O(n²) pass that is often a
grouping or deduplication written the long way.

```swift
struct NestedLoops {
    // flagged
    func duplicates(_ values: [Int]) -> [Int] {
        var found: [Int] = []
        for (i, a) in values.enumerated() {
            for (j, b) in values.enumerated() where i != j && a == b {
                found.append(a)
            }
        }
        return found
    }

    // accepted -- one pass, counted
    func duplicatesCounted(_ values: [Int]) -> [Int] {
        var counts: [Int: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.filter { $0.value > 1 }.map(\.key)
    }
}
```

### `complexity.repeated-linear-search`

The same collection searched linearly several times in one function. Any single search is fine;
the finding is about the accumulation.

```swift
struct RepeatedSearch {
    // flagged -- three linear passes over `names`
    func summary(_ names: [String]) -> String {
        let first = names.first { $0.hasPrefix("a") } ?? ""
        let second = names.first { $0.hasPrefix("b") } ?? ""
        let third = names.first { $0.hasPrefix("c") } ?? ""
        return first + second + third
    }
}
```

### `complexity.sort-in-loop`

A sort inside a loop. Sorting is O(n log n); doing it per iteration multiplies that by the loop.
Usually the sort can be hoisted, because the collection is not changing.

```swift
struct SortInLoop {
    // flagged
    func topPerRound(_ rounds: Int, values: [Int]) -> [Int] {
        var picks: [Int] = []
        for _ in 0..<rounds {
            picks.append(values.sorted().last ?? 0)
        }
        return picks
    }

    // accepted -- sort once, outside
    func topPerRoundHoisted(_ rounds: Int, values: [Int]) -> [Int] {
        let best = values.max() ?? 0
        return Array(repeating: best, count: rounds)
    }
}
```

### `complexity.quadratic-string-concat`

Building a string by repeated concatenation reallocates as it grows.

```swift
struct StringBuilding {
    // flagged
    func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts { result += part + "," }
        return result
    }

    // accepted
    func joinFast(_ parts: [String]) -> String {
        parts.joined(separator: ",")
    }
}
```

### `complexity.call-graph-amplification`

A function that looks cheap but calls an expensive one inside a loop. This is the rule that
needs a call graph: nothing in the flagged function's own text says it is quadratic.

```swift
struct Amplification {
    func expensive(_ values: [Int], target: Int) -> Bool {
        values.contains(target)          // linear
    }

    // flagged -- linear callee, called per element
    func check(_ values: [Int], targets: [Int]) -> Int {
        var hits = 0
        for target in targets where expensive(values, target: target) { hits += 1 }
        return hits
    }
}
```

The estimate follows calls to a configurable depth (`callGraphMaxDepth`, default 1). Costs for
standard library operations come from a built-in table; add your own with `knownCosts` when a
project has a function whose cost the analyzer cannot infer.

### `complexity.cross-module-amplification`

The only warning in the analyzer. A function's cognitive complexity, once the complexity of its
cross-module callees is folded in, exceeds the amplified threshold (default 30).

This needs an index store, because module boundaries are exactly what a single file's syntax
cannot see. It is a warning rather than a note because the shape it describes — a thin-looking
function fronting a large amount of work in another target — is the one most likely to surprise
a reader who only opens one file.

### `complexity.index-pass.skipped`

Not a defect: a statement that cross-module analysis did not run because no index store was
available. Build the project and the pass runs. It is reported explicitly so that a smaller set
of findings is never mistaken for a cleaner codebase.

## Configuration

| Option | Default | Effect |
|--------|---------|--------|
| `cognitiveThreshold` | 15 | Threshold for `complexity.cognitive-threshold` |
| `moduleThresholds` | `[:]` | Per-module overrides for the above |
| `amplifiedCognitiveThreshold` | 30 | Threshold for the cross-module warning |
| `reportTopN` | 10 | How many of the worst functions to report |
| `callGraphEnabled` | `true` | Follow calls when estimating cost |
| `callGraphMaxDepth` | 1 | How far to follow them |
| `crossModuleAmplification` | `true` | Run the index-backed pass |
| `knownCosts` | `[]` | Costs for functions the analyzer cannot infer |

## How to act on a finding

Treat it as a place to look, not a conclusion. The estimate is derived from structure — loop
nesting, known costs, call edges — and structure is a good predictor of cost, not a measurement
of it.

The analyzer proved that on itself. It reported `CallGraphAmplifier.buildCostMap` as
*"cognitive complexity 37, estimated O(n³)"*. The nested loops were real. The actual bottleneck
was elsewhere: a `SourceLocationConverter` built once per function rather than once per file,
which a profiler found in one run and which took a 259 KB fixture from 53.83s to 5.50s.

So: read the finding, then measure. And if a build step or a checker is slow, read this
analyzer's output first — it is cheaper than a profiler and it narrows the search.
