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
class User {
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
struct Settings {
    var fontSize: Int {
        return self.fontSize
    }
}

// accepted
struct Settings {
    private let _fontSize: Int = 14
    var fontSize: Int { _fontSize }  // reads backing storage
}
```

Both bare `fontSize` and `self.fontSize` references inside the getter are detected.

### `recursion.setter-self`

A computed property setter that assigns to its own property name triggers infinite recursion. The setter calls itself instead of writing to backing storage.

```swift
// flagged
struct Settings {
    private var _fontSize: Int = 14
    var fontSize: Int {
        get { _fontSize }
        set { fontSize = newValue }  // assigns to itself
    }
}

// accepted
struct Settings {
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
struct Matrix {
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
struct Matrix {
    var storage: [Double] = []
    let columns: Int

    subscript(row: Int, col: Int) -> Double {
        get { storage[row * columns + col] }
        set { self[row, col] = newValue }  // writes to own subscript
    }
}

// accepted
struct Matrix {
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
protocol Describable {
    var name: String { get }
    func describe() -> String
}

extension Describable {
    func describe() -> String {
        "Describable: \(name)"  // delegates to a different requirement
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
func flatten(_ nested: [[Int]], index: Int = 0) -> [Int] {
    guard index < nested.count else { return [] }
    return nested[index] + flatten(nested, index: index + 1)
}
```

The base case heuristic looks for `guard` statements, bare `return` statements, or `return <non-call>` expressions. If your base case is an `if` check rather than a `guard`, refactor it to `guard` -- this silences the warning and is generally clearer code.

```swift
// flagged (if-based base case not recognized)
func factorial(_ n: Int) -> Int {
    if n <= 1 { return 1 }
    return n * factorial(n - 1)
}

// accepted (same logic, guard-based)
func factorial(_ n: Int) -> Int {
    guard n > 1 else { return 1 }
    return n * factorial(n - 1)
}
```

This rule also applies to instance methods, static methods, async functions, throwing functions, and generic functions. The recursion shape does not change with those modifiers.

### `recursion.mutual-cycle`

Two or more functions that call each other in a cycle with no guard-driven base case among any of the participants. The auditor builds a project-wide call graph and runs Tarjan's SCC algorithm to find these cycles, including across files.

```swift
// flagged (both participants reported)
func isEven(_ n: Int) -> Bool {
    isOdd(n - 1)
}

func isOdd(_ n: Int) -> Bool {
    isEven(n - 1)
}

// accepted (one participant has a base case)
func isEven(_ n: Int) -> Bool {
    guard n > 0 else { return true }
    return isOdd(n - 1)
}

func isOdd(_ n: Int) -> Bool {
    return isEven(n - 1)
}
```

A cycle is only reported if **none** of its participants have a guard-driven early exit. Adding a `guard` to any single participant silences the warning for the entire cycle. Three-node cycles (`a -> b -> c -> a`) produce three diagnostics, one per participant.

Cross-file cycles are detected via `auditProject`. Cross-module cycles (across SPM target boundaries) are out of scope.

## Overload safety

Argument labels are part of function identity. A function `f(_:)` calling `f(x:)` is calling a *different* overload, not itself. The auditor tracks labels precisely to avoid this common false-positive landmine.

```swift
// NOT flagged -- different overloads
func process(_ value: Int) {
    process(value: value)  // calls process(value:), a different function
}

func process(value: Int) {
    // different implementation
}
```

## False positives and how to suppress them

The auditor has no inline suppression comment (like `// RECURSION-SAFE:`). Instead, each rule has a structural escape hatch -- fixing the code shape that triggers the rule:

- **convenience-init-self**: Delegate to an initializer with different argument labels.
- **computed-property-self, setter-self**: Introduce a private backing storage property (`_name`) and reference that instead.
- **subscript-self, subscript-setter-self**: Delegate to a backing collection rather than `self[...]`.
- **protocol-extension-default-self**: Call a different protocol requirement or concrete helper from the default implementation.
- **unconditional-self-call**: Add a `guard` clause that returns or throws before the recursive call. If your base case uses `if`, refactor it to `guard` -- this is the intended escape hatch and produces clearer code.
- **mutual-cycle**: Add a `guard`-driven base case to at least one participant in the cycle.

If the auditor flags a pattern you believe is correct (e.g., an intentional trampoline or event loop), the recommended approach is to add a `guard` with a termination condition. If you find a class of legitimate code that is consistently flagged, open an issue -- the heuristic may need refinement.
