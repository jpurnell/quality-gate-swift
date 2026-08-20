# ``RecursionAuditor``

Detects infinite-recursion bugs in Swift source before they reach SourceKit or runtime.

## Overview

RecursionAuditor uses SwiftSyntax to walk every function, initializer, computed property, and subscript in a Swift project, looking for the most common patterns that produce infinite recursion. It runs purely on the AST — no successful build, no IndexStore, no type checker. It works at the file level for most rules and project-wide for mutual cycle detection.

The auditor was motivated by a real incident: a convenience initializer that forwarded to `self.init(...)` with identical arguments. The code compiled cleanly; SourceKit caught it after the fact. This auditor catches the same class of bug at quality-gate time.

### Detected patterns

| Rule ID | Severity | What it catches |
|---------|----------|-----------------|
| `recursion.convenience-init-self` | error | A convenience initializer whose `self.init(...)` call uses the same argument labels as the enclosing init |
| `recursion.computed-property-self` | error | A computed property whose getter resolves a reference back to the same property |
| `recursion.subscript-self` | error | A subscript getter that calls `self[…]` |
| `recursion.setter-self` | error | A property setter that assigns to its own property name |
| `recursion.subscript-setter-self` | error | A subscript setter that assigns to `self[…]` |
| `recursion.protocol-extension-default-self` | error | A function in a protocol extension whose default implementation calls itself |
| `recursion.unconditional-self-call` | warning | A function that recurses with no base case |
| `recursion.self-reference-unresolved` | note | A self-named call whose overload syntax cannot resolve |
| `recursion.mutual-cycle` | warning | A cycle in the project-wide call graph where no participant has a base case |

### Mutual cycle detection

The auditor builds a project-wide call graph keyed by qualified name (`Type.method(label:)`) and runs Tarjan's strongly-connected-components algorithm to find cycles. A cycle is reported only if **none** of its participants have a guard-driven early exit. Both intra-file and cross-file cycles are detected; cross-module cycles are out of scope for v1.

Mutual cycles fire `recursion.mutual-cycle` for every participant in the cycle, so a 3-node cycle produces 3 diagnostics.

### Base case heuristic

A function is considered to "have a base case" if its body contains any `guard` statement. This is intentionally conservative — it can miss base cases expressed as `if n <= 0 { return 0 }`, producing false positives. The escape hatch is to refactor the early exit into a guard, which is generally clearer anyway.

### Overload safety

Argument labels are part of function identity. `func f(_ x: Int)` calling `f(x: x)` is recognized as calling a *different* overload (`f(x:)`), not as self-recursion.

Labels are not *all* of a function's identity, though. Two declarations sharing a base name **and** labels differ only in parameter types, and choosing between them is type resolution, which no syntactic pass can perform — GRDB declares fourteen `encode(_:)` overloads in one file, and `encode(_ value: Int16)` calling `encode(value.databaseValue)` targets a sibling, not itself. Where the census finds more than one implementation of a signature, the site is recorded as `recursion.self-reference-unresolved` at note severity rather than asserted as recursion. The census is project-wide, because a Swift type spans files.

Subscripts are resolved the same way, with one extra wrinkle: they do **not** promote a
parameter name to an argument label the way functions do. `subscript(index: Int)` is called
`self[index]` with no label at all; a label appears only when a second name is written, as in
`subscript(index index: Int)`. Comparing labels at all — the rule previously matched every
`self[…]` regardless — is what separates SwiftyJSON's five subscripts from one another.

Two clarifications this rule pays for:

- A protocol **requirement** and the extension default satisfying it share a signature but are one function. Only declarations with bodies count toward the census, or the pair would silence the very rule that catches `extension P { func f() { f() } }`.
- An extension of a nested type shares that type's context: `extension Row.ScopesView`
  resolves to `Row.ScopesView`, matching what `struct ScopesView` nested in `Row` builds from
  its lexical stack. Yielding only `ScopesView` split the two halves of a type across separate
  contexts, so declarations in one half could never see overloads in the other.
- Direct self-recursion and a mutual cycle need *different* base-case tests. A branch returning some other call bounds the first and not the second, since that call may be the next participant in the cycle. The two questions are asked separately.

### Syntax is not binding

Walking the AST is not automatically semantic. SwiftSyntax knows that `return sql` is a
`DeclReferenceExprSyntax` named `sql`; it cannot know whether that resolves to the enclosing
property or to a local declared two lines earlier. A tree walk without a scope stack beats a
regex — it will not match inside comments or string literals — but it is still name matching,
and a survey of 22 third-party packages found it reporting recursion that was not recursion.

Pass 1 therefore performs **lexical** resolution before reporting. Three constructs carry the
property's name without referring to it:

```swift
struct Storage { var retryCount = 0 }

struct Protected {
    private let storage = Storage()
    func read<T>(_ keyPath: KeyPath<Storage, T>) -> T { storage[keyPath: keyPath] }
}

struct Request {
    private let mutableState = Protected()

    /// `\.retryCount` is a key path into `Storage`, not a reference to this property.
    var retryCount: Int { mutableState.read(\.retryCount) }

    /// The local `status` shadows the property for the rest of the getter.
    var status: Int {
        let status = 1
        return status
    }

    func label(style: Int = 0) -> String { "" }

    /// `label()` resolves to the method above — a different declaration. Swift
    /// permits the pair because the method's full name is `label(style:)`.
    var label: String { label() }
}
```

Resolution stops there. Type-based questions — a typealias, a protocol witness, a generic
constraint — belong to the index-backed pass, which has the compiler's own answer and says so
when no index is available. The boundary is deliberate: a foreign checkout has no index store,
and that is exactly where these rules were proven wrong, so Pass 1 must stay useful without one.

### Out of scope

- Resolving an overload by parameter type. Recorded as `self-reference-unresolved`, not adjudicated. Doing so needs USR identity **and** per-symbol base-case data; the index pass has the first and not the second — `baseCaseUSRs` is passed empty today, and computed properties never record a base case at all.
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
