# ``RecursionAuditor``

Detects infinite-recursion bugs in Swift source before they reach SourceKit or runtime.

## Overview

RecursionAuditor uses SwiftSyntax to walk every function, initializer, computed property, and subscript in a Swift project, looking for the most common patterns that produce infinite recursion. It runs purely on the AST — no successful build, no IndexStore, no type checker. It works at the file level for most rules and project-wide for mutual cycle detection.

The auditor was motivated by a real incident: a convenience initializer that forwarded to `self.init(...)` with identical arguments. The code compiled cleanly; SourceKit caught it after the fact. This auditor catches the same class of bug at quality-gate time.

### Detected patterns

| Rule ID | Severity | What it catches |
|---------|----------|-----------------|
| `recursion.convenience-init-self` | error | A convenience initializer whose `self.init(...)` call uses the same argument labels as the enclosing init |
| `recursion.computed-property-self` | error | A computed property whose getter references the same property name |
| `recursion.subscript-self` | error | A subscript getter that calls `self[…]` |
| `recursion.setter-self` | error | A property setter that assigns to its own property name |
| `recursion.subscript-setter-self` | error | A subscript setter that assigns to `self[…]` |
| `recursion.protocol-extension-default-self` | error | A function in a protocol extension whose default implementation calls itself |
| `recursion.unconditional-self-call` | warning | A function that recurses with no guard-driven base case |
| `recursion.mutual-cycle` | warning | A cycle in the project-wide call graph where no participant has a base case |

### Mutual cycle detection

The auditor builds a project-wide call graph keyed by qualified name (`Type.method(label:)`) and runs Tarjan's strongly-connected-components algorithm to find cycles. A cycle is reported only if **none** of its participants have a guard-driven early exit. Both intra-file and cross-file cycles are detected; cross-module cycles are out of scope for v1.

Mutual cycles fire `recursion.mutual-cycle` for every participant in the cycle, so a 3-node cycle produces 3 diagnostics.

### Base case heuristic

A function is considered to "have a base case" if its body contains any `guard` statement. This is intentionally conservative — it can miss base cases expressed as `if n <= 0 { return 0 }`, producing false positives. The escape hatch is to refactor the early exit into a guard, which is generally clearer anyway.

### Overload safety

Argument labels are part of function identity. `func f(_ x: Int)` calling `f(x: x)` is recognized as calling a *different* overload (`f(x:)`), not as self-recursion. This avoids a common false-positive landmine.

### Out of scope

- Cross-module recursion across SPM target boundaries (would require IndexStore)
- Indirect recursion through closures or function references
- `didSet`/`willSet` property observer mutation cycles
- Control-flow constant folding (`if true { return f() }`)
- Recursive value-type definitions (`indirect enum List`) — these are not call recursion and are explicitly not flagged

## Topics

### Guides

- <doc:RecursionAuditorGuide>

### Essentials

- ``RecursionAuditor/check(configuration:)``
- ``RecursionAuditor/auditSource(_:fileName:configuration:)``
- ``RecursionAuditor/auditProject(sources:configuration:)``
