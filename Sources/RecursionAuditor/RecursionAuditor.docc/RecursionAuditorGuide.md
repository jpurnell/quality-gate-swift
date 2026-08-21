# RecursionAuditor Guide

A practical walkthrough of every RecursionAuditor rule, with the bug it catches and the recommended fix.

## Why this auditor exists

Infinite recursion is one of the easiest bugs to write in Swift and one of the hardest for the compiler to catch. A convenience initializer that forwards to itself with matching argument labels compiles without a single warning. A computed property getter that returns `self.value` instead of `_value` looks perfectly reasonable in code review. These patterns crash at runtime with a stack overflow -- and nothing in `swiftc` or SourceKit reliably prevents them ahead of time.

RecursionAuditor uses SwiftSyntax to walk every function, initializer, computed property, and subscript in a project, checking for the structural patterns that produce infinite recursion. It runs on the raw AST -- no successful build required, no IndexStore, no type checker. Single-file rules catch the most common shapes; a project-wide call graph with Tarjan's strongly-connected-components algorithm catches mutual recursion across files.

## Rule walkthrough

### `recursion.convenience-init-self`

A convenience initializer whose `self.init(...)` call uses the exact same argument labels as the enclosing init is calling itself, not a different designated initializer. This compiles cleanly and crashes at runtime.

```swift
// flagged
class User {
    let name: String
    let role: String

    init(name: String, role: String) {
        self.name = name
        self.role = role
    }

    convenience init(name: String) {
        self.init(name: name)  // same labels as this init -- infinite loop
    }
}

// accepted
class FixedUser {
    let name: String
    let role: String

    init(name: String, role: String) {
        self.name = name
        self.role = role
    }

    convenience init(name: String) {
        self.init(name: name, role: "viewer")  // different labels -- calls designated init
    }
}
```

Argument labels are the identity signal. `self.init(name:)` calling `init(name:role:)` is safe because the label lists differ.

### `recursion.computed-property-self`

A computed property whose getter references the same property name reads itself, producing infinite recursion. This is especially common when a developer adds a computed wrapper and forgets to rename the backing storage.

```swift
// flagged
struct Settings {
    var fontSize: Int { fontSize }  // reads itself
}

// also flagged (explicit self and return)
struct SettingsExplicitSelf {
    var fontSize: Int {
        return self.fontSize
    }
}

// accepted
struct FixedSettings {
    private let _fontSize: Int = 14
    var fontSize: Int { _fontSize }  // reads backing storage
}
```

Both bare `fontSize` and `self.fontSize` references inside the getter are detected.

Three things carry the property's name without referring to it, and none of them are flagged.
Each was found misreporting real code in a survey of 22 open-source packages:

```swift
struct Stat { var mode = 0 }
struct Storage { var retryCount = 0 }
struct Protected {
    private let storage = Storage()
    func read<T>(_ keyPath: KeyPath<Storage, T>) -> T { storage[keyPath: keyPath] }
}

struct NotFlagged {
    private let mutableState = Protected()

    // a local shadows the property for the rest of the getter
    var status: Stat {
        var status = Stat()
        status.mode = 1
        return status
    }

    // the key path addresses `Storage`, not this property
    var retryCount: Int { mutableState.read(\.retryCount) }

    // resolves to the method, which Swift permits alongside the property
    // because the method's full name is `asISO8601(style:)`
    func asISO8601(style: Int = 0) -> String { "" }
    var asISO8601: String { asISO8601() }
}
```

`self.name` is deliberately *not* subject to shadowing: it names the property whatever locals
exist, so `let name = "x"; return self.name` is still infinite recursion and is still reported.

### `recursion.setter-self`

A computed property setter that assigns to its own property name triggers infinite recursion. The setter calls itself instead of writing to backing storage.

```swift
// flagged
struct SetterSettings {
    private var _fontSize: Int = 14
    var fontSize: Int {
        get { _fontSize }
        set { fontSize = newValue }  // assigns to itself
    }
}

// accepted
struct FixedSetterSettings {
    private var _fontSize: Int = 14
    var fontSize: Int {
        get { _fontSize }
        set { _fontSize = newValue }  // assigns to backing storage
    }
}
```

Both `fontSize = newValue` and `self.fontSize = newValue` are caught.

### `recursion.subscript-self`

A subscript getter that calls `self[...]` is reading from itself, producing infinite recursion. The fix is to delegate to a backing collection.

```swift
// flagged
struct Matrix {
    subscript(row: Int, col: Int) -> Double {
        self[row, col]  // calls own subscript
    }
}

// accepted
struct FixedMatrix {
    private var storage: [Double] = []
    let columns: Int

    subscript(row: Int, col: Int) -> Double {
        storage[row * columns + col]  // delegates to backing array
    }
}
```

### `recursion.subscript-setter-self`

A subscript setter that assigns to `self[...]` writes to itself, producing infinite recursion. Same shape as the getter variant but in the `set` accessor.

```swift
// flagged
struct SubscriptSetterMatrix {
    var storage: [Double] = []
    let columns: Int

    subscript(row: Int, col: Int) -> Double {
        get { storage[row * columns + col] }
        set { self[row, col] = newValue }  // writes to own subscript
    }
}

// accepted
struct FixedSubscriptSetterMatrix {
    var storage: [Double] = []
    let columns: Int

    subscript(row: Int, col: Int) -> Double {
        get { storage[row * columns + col] }
        set { storage[row * columns + col] = newValue }  // writes to backing array
    }
}
```

### `recursion.protocol-extension-default-self`

A function in a protocol extension whose default implementation calls itself will infinitely recurse for any conformer that does not override it. The compiler has no way to enforce that every conformer overrides the method, so this is an error-severity rule.

```swift
// flagged
protocol Describable {
    func describe() -> String
}

extension Describable {
    func describe() -> String {
        describe()  // any type relying on the default will crash
    }
}

// accepted
protocol FixedDescribable {
    var name: String { get }
    func describe() -> String
}

extension FixedDescribable {
    func describe() -> String {
        "FixedDescribable: \(name)"  // delegates to a different requirement
    }
}
```

### `recursion.unconditional-self-call`

A function that calls itself with no guard-driven base case will recurse until the stack overflows. This is a warning (not an error) because some recursive shapes are intentional event loops or trampolines -- but most are bugs.

```swift
// flagged (warning)
func flatten(_ nested: [[Int]]) -> [Int] {
    return flatten(nested)  // no base case
}

// accepted
func guardedFlatten(_ nested: [[Int]], index: Int = 0) -> [Int] {
    guard index < nested.count else { return [] }
    return nested[index] + guardedFlatten(nested, index: index + 1)
}
```

A base case is **any branch that exits without re-entering this function** — a `guard`, a bare
`return`, a returned value, or a returned call to something else. `if` is as good as `guard`:

```swift
// accepted -- an `if` base case is a base case
func factorial(_ n: Int) -> Int {
    if n <= 1 { return 1 }
    return n * factorial(n - 1)
}
```

> An earlier version of this guide claimed the example above *was* flagged and advised
> refactoring `if` into `guard` to silence it. That was wrong, and wrong from the beginning —
> the rule has always accepted a returned non-call. The advice is withdrawn: write whichever
> reads better.

Two shapes the heuristic genuinely used to miss, both found in the survey and both now accepted:

```swift
struct Expression {
    let impl: Int

    // accepted -- the terminating branch returns a *different* call.
    // GRDB's SQLExpression.between ends this way, with `self.init(...)`.
    static func between(lower: Int, upper: Int) -> Expression {
        if lower < 0 { return between(lower: -lower, upper: upper) }
        return Expression(impl: lower + upper)
    }
}

// accepted -- an implicit return: the branch value of an `if` expression, with
// no `return` keyword anywhere. Ignite's flatten(_:) terminates this way.
func descend(_ depth: Int) -> [Int] {
    if depth > 0 {
        descend(depth - 1)
    } else {
        []
    }
}
```

This rule also applies to instance methods, static methods, async functions, throwing functions, and generic functions. The recursion shape does not change with those modifiers.

### `recursion.self-reference-unresolved`

A note, not a finding: a self-named call the syntactic pass could not resolve, in a file the
index pass could not see.

Argument labels are part of a function's identity but not all of it. Swift chooses between
same-labelled overloads by **parameter type**, which no syntactic pass can do — GRDB declares
fourteen `encode(_:)` overloads in one file, and `encode(_ value: Int16)` calling
`encode(value.databaseValue)` targets a sibling rather than itself. Where a signature has more
than one implementation, the auditor records the site instead of asserting recursion.

With an index store the question is settled automatically: overloads are distinct symbols there,
so the call produces no self-edge and no finding. A site that reaches this note is therefore one
the index could not see — code excluded by a platform condition or a package trait, a test target
(the index comes from `swift build`, which does not build tests), or a failed index build. The
pass reports which applies, and never lets an index that saw nothing erase findings it did not
examine.

### `recursion.mutual-cycle`

Two or more functions that call each other in a cycle with no base case among any of the
participants. A cycle asks a *stricter* base-case question than direct recursion does: a branch
returning some other call bounds a self-call, but not a cycle, because that call may be the next
participant. The two tests are asked separately for that reason. The auditor builds a project-wide call graph and runs Tarjan's SCC algorithm to find these cycles, including across files.

```swift
// flagged (both participants reported)
func isEven(_ n: Int) -> Bool {
    isOdd(n - 1)
}

func isOdd(_ n: Int) -> Bool {
    isEven(n - 1)
}

// accepted (one participant has a base case)
func guardedIsEven(_ n: Int) -> Bool {
    guard n > 0 else { return true }
    return guardedIsOdd(n - 1)
}

func guardedIsOdd(_ n: Int) -> Bool {
    return guardedIsEven(n - 1)
}
```

A cycle is only reported if **none** of its participants have a guard-driven early exit. Adding a `guard` to any single participant silences the warning for the entire cycle. Three-node cycles (`a -> b -> c -> a`) produce three diagnostics, one per participant.

Cross-file cycles are detected via `auditProject`. Cross-module cycles (across SPM target boundaries) are out of scope.

## Overload safety

Argument labels are part of function identity. A function `f(_:)` calling `f(x:)` is calling a *different* overload, not itself. The auditor tracks labels precisely to avoid this common false-positive landmine.

Labels are not *all* of the identity, though, and the auditor does not pretend otherwise: where
two declarations share a base name **and** labels, only their parameter types separate them, and
that is a question for the compiler. See `recursion.self-reference-unresolved` above.

Subscripts are resolved the same way, with one wrinkle worth knowing: a subscript does **not**
promote a parameter name to an argument label the way a function does. `subscript(index: Int)` is
called `self[index]` with no label at all; a label appears only when a second name is written, as
in `subscript(index index: Int)`.

```swift
// NOT flagged -- different overloads
enum OverloadSafety {
    static func process(_ value: Int) {
        process(value: value)  // calls process(value:), a different function
    }

    static func process(value: Int) {
        // different implementation
    }
}
```

## False positives and how to suppress them

The auditor has no inline suppression comment (like `// RECURSION-SAFE:`). Instead, each rule has a structural escape hatch -- fixing the code shape that triggers the rule:

- **convenience-init-self**: Delegate to an initializer with different argument labels.
- **computed-property-self, setter-self**: Introduce a private backing storage property (`_name`) and reference that instead.
- **subscript-self, subscript-setter-self**: Delegate to a backing collection rather than `self[...]`.
- **protocol-extension-default-self**: Call a different protocol requirement or concrete helper from the default implementation.
- **unconditional-self-call**: Add a branch that returns or throws without calling the function again. `if` and `guard` both count; so does returning a call to something else.
- **mutual-cycle**: Add a base case to at least one participant. Here the bar is higher than for a
  self-call — the branch must not call *any* participant, since a returned call may be the next
  one round the cycle.

If the auditor flags a pattern you believe is correct (e.g., an intentional trampoline or event loop), the recommended approach is to add an explicit termination condition. If you find a class of legitimate code that is consistently flagged, open an issue -- the heuristic may need refinement.
