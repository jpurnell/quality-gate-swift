# ``ComplexityAnalyzer``

Measures how hard each function is to read, and estimates what it costs to run.

## Overview

ComplexityAnalyzer answers two questions about every function in a project. **How hard is this
to hold in your head?** — cognitive complexity, computed by walking the AST. And **what does it
cost as the input grows?** — a time-complexity estimate derived from loop nesting, standard
library operations with known costs, recursion shape, and calls into other functions.

The second question is the one a reviewer cannot answer by reading. A function with a single
loop looks linear until you notice the `contains` inside it, or the callee two modules away that
sorts. The analyzer follows those edges so the cost estimate reflects the program rather than
the page.

Everything it reports is **advisory**. Findings are notes, with a single warning for the
cross-module case. Complexity is a judgement about design, and a gate that blocks a commit over
a judgement is a gate people route around. It reports; you decide.

### The two passes

**Pass 1 is syntactic** and always runs. It computes cognitive complexity per function, detects
quadratic patterns within a file, and estimates each function's time complexity — including
amplification through calls it can resolve inside the module.

**Pass 2 is index-backed** and runs when an index store is available. It follows calls *across
module boundaries*, which the syntax of one file cannot see: a function that looks trivial may
call something expensive in another target. When no index exists the pass says so
(`complexity.index-pass.skipped`) rather than silently reporting a smaller number.

### Rules

| Rule ID | Severity | What it reports |
|---------|----------|-----------------|
| `complexity.cognitive-threshold` | note | A function above the cognitive complexity threshold (default 15) |
| `complexity.contains-in-filter` | note | A linear search inside a filter — quadratic over the collection |
| `complexity.nested-loop-same-collection` | note | Two loops over the same collection, nested |
| `complexity.repeated-linear-search` | note | The same collection searched linearly, repeatedly |
| `complexity.sort-in-loop` | note | A sort inside a loop |
| `complexity.quadratic-string-concat` | note | String accumulation that reallocates per iteration |
| `complexity.call-graph-amplification` | note | A cheap-looking function calling an expensive one inside a loop |
| `complexity.cross-module-amplification` | warning | Cognitive complexity above the amplified threshold (default 30) once cross-module callees are counted |
| `complexity.index-pass.skipped` | note | No index store, so cross-module analysis did not run |

### Cognitive complexity, specifically

The SonarSource algorithm, not cyclomatic complexity. Two rules:

- **+1** for each break in linear flow — `if`, `else if`, `for`, `while`, `catch`, and so on.
- **+1 additional** for each level of enclosing nesting.

The nesting increment is what separates it from cyclomatic complexity, and it is the part that
matches intuition: ten sequential `if` statements are tedious, while three `if` statements nested
three deep are genuinely hard to reason about. The second shape scores higher, as it should.

## What this analyzer found in itself

`CallGraphAmplifier.buildCostMap` was reported by this checker, against this repository, as
*"cognitive complexity 37 (threshold: 15), estimated O(n³)"*. The gate passed anyway, because
these findings are advisory — and the note sat there while the checker itself was the slowest in
the suite.

It is worth being precise about what that finding was and was not worth. The nested loops it
named are real. But when the bottleneck was finally measured with a profiler, the cost was
somewhere else entirely: **62% of a run was `SourceLocationConverter` construction**, one built
per function, each indexing every line in the file — O(functions × file). Hoisting it to one per
file took a 259 KB fixture from **53.83s to 5.50s**, and the growth curve from **n^1.81 to
n^0.83**.

Two lessons, and the analyzer's own documentation is the right place to keep them:

- **An estimate is a hypothesis, not a measurement.** This checker's `O(n³)` was a structural
  guess from loop nesting. It pointed at real code and still did not name the bottleneck. Treat
  a complexity finding as a place to look, never as a conclusion.
- **Advisory findings are only useful if somebody reads them.** The note was correct, present,
  and ignored for weeks. If a long-running process is the problem, this checker's output is the
  first place to look — which is the whole reason it exists.

## Topics

### Guides

- <doc:ComplexityAnalyzerGuide>

### Essentials

- ``ComplexityAnalyzer/check(configuration:)``
- ``ComplexityAnalyzer/scanProject(configuration:)``
- ``ComplexityAnalyzer/analyzeSource(_:filePath:moduleName:callGraphEnabled:callGraphMaxDepth:userCosts:)``

### Model

- ``FunctionComplexityRecord``
- ``ComplexityPattern``
- ``ComplexityBasis``
- ``EstimationConfidence``
- ``RecursionClassification``

### Call graph

- ``CallGraph``
- ``CallEdge``
- ``CrossModuleCallEdge``
- ``CognitiveComplexityVisitor``
