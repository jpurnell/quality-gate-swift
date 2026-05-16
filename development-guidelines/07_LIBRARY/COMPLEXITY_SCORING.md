# Complexity Scoring Reference

This guide explains the two complexity metrics used by the Algorithmic Complexity Checker:
**Cognitive Complexity** and **Estimated Big-O Time Complexity**.

## Cognitive Complexity

Cognitive complexity measures how difficult a function is for a human to understand.
It was formalized by SonarSource and rewards flat, guard-based control flow over
deeply nested structures.

### Scoring Algorithm

The AST visitor applies two rules:

1. **+1 for each break in linear flow**: `if`, `else if`, `else`, `for`, `while`,
   `repeat`, `switch`, `catch`, `guard...else`, ternary `?:`, nil-coalescing `??`,
   logical operator sequences (`&&`, `||` — counted per *sequence*, not per operator)

2. **+1 nesting increment** for each level of nesting when a new break occurs

### Worked Example

```swift
func example(items: [Item]) {                // 0
    for item in items {                      // +1 (flow break)
        if item.isValid {                    // +2 (flow break +1, nesting +1)
            guard let x = item.value else {  // +3 (flow break +1, nesting +2)
                continue
            }
        }
    }
}                                            // Total: 6
```

### Key Design Choices

- Early returns and flat `guard` at the top of a function do NOT compound nesting.
  This rewards the Swift idiom of guarding preconditions early.
- A sequence of `else if` does not compound like nested `if` — it's treated as a
  flat decision list.
- `switch` increments once for the statement; individual `case` branches do not
  add additional increments (they're expected structure, not breaks in flow).
- Logical operators (`&&`, `||`) within a single condition count as +1 per
  *sequence change* (e.g., `a && b && c` is +1, but `a && b || c` is +2).

### Interpretation

| Score | Interpretation |
|-------|---------------|
| 1-5   | Simple, easy to understand |
| 6-10  | Moderate, manageable with attention |
| 11-15 | Complex, consider refactoring |
| 16-25 | High, strongly consider breaking up |
| 25+   | Very high, likely needs decomposition |

These thresholds are advisory. Context matters — a parser's main dispatch loop
may legitimately score higher than a utility function.

## Estimated Big-O Time Complexity

Big-O measures how a function's execution time scales as input size grows.
Unlike cognitive complexity, Big-O is about computational behavior, not readability.

### Static Estimation Approach

Exact Big-O cannot be proven statically in the general case, but pattern-based
estimation catches the majority of real-world code:

1. **Loop nesting depth** over related collections implies O(n^depth)
2. **Known stdlib operation costs**:
   - `Array.contains`, `Array.first(where:)`, `Array.filter` — O(n)
   - `Set.contains`, `Set.insert`, `Dictionary` subscript — O(1)
   - `Array.sort`, `Array.sorted` — O(n log n)
   - `Array.append` — amortized O(1)
3. **Recursion patterns**:
   - Linear recursion (no division) — O(n) or worse
   - Divide-and-conquer (halving input) — O(n log n)
   - Branching recursion without memoization — O(2^n)
4. **Call-graph amplification**: A loop containing a call to a function with its
   own estimated complexity compounds (e.g., O(n) loop calling O(n) function = O(n^2))

### Relationship to Cognitive Complexity

These metrics measure fundamentally different things:

| Scenario | Cognitive | Big-O |
|----------|-----------|-------|
| Deeply nested validation, no loops | High | O(1) |
| Clean two-line recursive mergesort | Low | O(n log n) |
| Nested loops over same collection | High | O(n^2) |
| Simple linear scan | Low | O(n) |

In practice they correlate (nested loops drive both up) but diverge enough
to warrant independent tracking.

## Structured Data Model

Both metrics are recorded per-function:

```
cognitiveComplexity: Int            // Deterministic, exact count
estimatedTimeComplexity: String     // "O(1)", "O(n)", "O(n^2)", etc.
complexityBasis: [String]           // Patterns that drove the estimate
confidence: low | medium | high     // Certainty of the Big-O estimate
```

### Confidence Levels

- **high**: Single loop or no loops, no external calls with unknown complexity
- **medium**: Nested loops with clear bounds, known stdlib operations
- **low**: Recursion with unclear termination, calls to functions with unknown
  complexity, dynamic dispatch where the concrete implementation varies

### complexityBasis Examples

```
["nested_loop:2", "stdlib:Array.contains"]     // O(n^2) from contains-in-loop
["recursion:linear", "no_memoization"]         // O(2^n) branching recursion
["single_loop", "stdlib:Dictionary.subscript"] // O(n) with O(1) inner ops
```

## Common Anti-Patterns Detected

These patterns are flagged as advisory findings:

- **contains-in-filter**: `array.filter { otherArray.contains($0) }` — O(n^2),
  suggest converting to Set first
- **nested-loop-same-collection**: Iterating the same or related collection in
  nested loops without early exit
- **repeated-linear-search**: Multiple `first(where:)` calls on the same
  collection that could be replaced with a dictionary lookup
- **sort-in-loop**: Calling `sorted()` inside a loop when the sort could be
  hoisted outside
- **quadratic-string-concat**: Building strings with `+=` in a loop instead of
  using `joined()` or array accumulation
