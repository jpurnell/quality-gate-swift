# PointerEscapeAuditor Guide

How Swift's borrow-vs-escape model works, why this auditor exists, and how to read its diagnostics.

## The borrow model

`withUnsafePointer(to: x) { ptr in … }` is a *borrow*. The pointer `ptr` is valid only inside the closure body. After the closure returns, the underlying memory is gone — sometimes deallocated, sometimes overwritten, sometimes still there but no longer guaranteed. Touching the pointer after that point is undefined behavior.

Swift's compiler checks the closure body for some escape patterns but stops at the boundary. Specifically, the compiler will not stop you from:

- Returning the pointer from the closure
- Assigning the pointer to a variable captured from outside
- Storing it in a property
- Capturing it in another closure that escapes

All of these compile cleanly. All of them are bugs.

## The motivating incident

Real session, paraphrased:

```swift
final class FFTBackend {
    var workspace: UnsafeMutablePointer<DSPSplitComplex>?

    func setup(input: [Float]) {
        input.withUnsafeBufferPointer { buf in
            self.workspace = buf.baseAddress.map { /* … pointer dance … */ }
        }
    }

    func transform() {
        // Use self.workspace later — but the underlying memory is gone.
    }
}
```

The result was intermittent memory corruption that manifested as test failures only under load. PointerEscapeAuditor catches this exact pattern at quality-gate time:

```
error: pointer escapes by being stored in a property
       FFTBackend.swift:14:13
       rule: pointer-escape.stored-in-property
       fix:  Store the pointee value or a Sendable copy instead.
```

## Rule walkthrough

### `pointer-escape.return-from-with-block`

Returning the pointer from the closure means the caller receives a dangling reference.

```swift
// ❌ flagged — direct
func leak(_ x: Int) -> UnsafePointer<Int> {
    withUnsafePointer(to: x) { $0 }
}

// ❌ flagged — derived
func leak2(_ a: [Int]) -> UnsafePointer<Int>? {
    a.withUnsafeBufferPointer { $0.baseAddress }
}

// ❌ flagged — wrapped
func leak3(_ x: Int) -> Holder {
    withUnsafePointer(to: x) { ptr in Holder(ptr: ptr) }
}

// ✅ accepted
func sum(_ x: Int) -> Int {
    withUnsafePointer(to: x) { $0.pointee }
}
```

The auditor catches the wrapped forms (struct init, tuple, array literal, `Any` box, ternary branches) by walking the returned expression for tracked pointer references — not just the top-level expression.

### `pointer-escape.assigned-to-outer-capture`

Assigning the pointer to anything captured from outside the closure stores a dangling reference where it can later be used.

```swift
// ❌ flagged
var leaked: UnsafePointer<Int>?
withUnsafePointer(to: x) { ptr in
    leaked = ptr
}

// ❌ flagged — defer is also walked
withUnsafePointer(to: x) { ptr in
    defer { leaked = ptr }
}
```

### `pointer-escape.stored-in-property`

Same shape, with `self.x =` as the assignment target. This is the FFT incident exactly.

### `pointer-escape.appended-to-outer-collection`

Easy to miss because it doesn't look like an assignment.

```swift
// ❌ flagged
var storage: [UnsafePointer<Int>] = []
withUnsafePointer(to: x) { ptr in
    storage.append(ptr)
}
```

### `pointer-escape.passed-as-inout`

A function whose contract is `inout UnsafePointer<Int>?` is structurally a "store this for me" sink. The auditor flags any call where a tracked pointer co-occurs with an `&outer` argument.

The same rule serves as the **conservative fallback** for any other non-allowlisted function call that takes a tracked pointer. The reasoning: without knowing the function's contract, the safest assumption is that it might store the pointer. The escape hatch is the `allowedEscapeFunctions` allowlist.

```swift
// ❌ flagged — strict inout pattern
withUnsafePointer(to: x) { ptr in
    assign(&leaked, ptr)
}

// ❌ flagged — conservative fallback
withUnsafePointer(to: x) { ptr in
    store(ptr)
}

// ✅ accepted — allowlisted
let auditor = PointerEscapeAuditor(allowedEscapeFunctions: ["vDSP_fft_zip"])
withUnsafePointer(to: x) { ptr in
    vDSP_fft_zip(ptr)
}
```

### `pointer-escape.stored-closure-captures-pointer`

A closure that captures a tracked pointer and is then stored or returned **escapes the pointer** even if it never appears bare in the assignment expression. The closure can be invoked later, after the with-block has returned.

```swift
// ❌ flagged
var closure: (() -> Void)?
withUnsafePointer(to: x) { ptr in
    closure = { print(ptr.pointee) }   // pointee is a value, but the closure
                                        // still captures `ptr` itself
}
```

This rule is at error tier because the escape is structurally provable: the closure captures the pointer name, and the closure is stored outside.

### `pointer-escape.captured-by-escaping-closure`

The warning-tier sibling. When the captured-pointer closure is passed to a known escaping API (`Task { … }`, `DispatchQueue.async { … }`, `DispatchQueue.asyncAfter { … }`), the rule fires at warning tier. Synchronous variants (`DispatchQueue.sync`, `forEach`, `map`) do NOT fire.

```swift
// ❌ flagged at warning tier
withUnsafePointer(to: x) { ptr in
    DispatchQueue.global().async {
        _ = ptr.pointee
    }
}

// ✅ accepted
withUnsafePointer(to: x) { ptr in
    DispatchQueue.global().sync {
        _ = ptr.pointee
    }
}
```

The distinction matters because escaping APIs run their closure after the call returns — which is exactly when the with-block has cleaned up.

### `pointer-escape.unmanaged-retain-leak`

`Unmanaged.passRetained(...).toOpaque()` adds a +1 retain that is your responsibility to release. If the auditor finds a `passRetained` call inside a class but no `.release()` call anywhere in that same class (typically in `deinit`), it warns.

```swift
// ❌ flagged
final class Holder {
    var handle: UnsafeMutableRawPointer?
    func capture(_ obj: AnyObject) {
        self.handle = Unmanaged.passRetained(obj).toOpaque()
    }
}

// ✅ accepted
final class Holder {
    var handle: UnsafeMutableRawPointer?
    func capture(_ obj: AnyObject) {
        self.handle = Unmanaged.passRetained(obj).toOpaque()
    }
    deinit {
        if let handle {
            Unmanaged<AnyObject>.fromOpaque(handle).release()
        }
    }
}
```

### `pointer-escape.opaque-roundtrip`

Round-tripping a pointer through `OpaquePointer` outside the with-block doesn't actually rescue it. The opaque form preserves the bits, not the validity.

```swift
// ❌ flagged at warning tier
let opaque = withUnsafePointer(to: x) { OpaquePointer($0) }
let typed = UnsafePointer<Int>(opaque)  // dangling
```

## Limitations

The auditor is intentionally intra-file and intra-function. It does **not** follow pointers across function boundaries. If you write:

```swift
func outer(_ x: Int) -> UnsafePointer<Int> {
    return inner(x)
}
func inner(_ x: Int) -> UnsafePointer<Int> {
    withUnsafePointer(to: x) { $0 }
}
```

The auditor catches the escape inside `inner` but does not connect `outer`'s return type to a flow. That's a deliberate scope limit, not an oversight. Cross-function pointer flow analysis would require IndexStore and a call graph, and would dramatically increase false-positive rates.

For the same reason, the auditor cannot tell whether a function you call internally stores the pointer. The conservative fallback (passed-as-inout) handles this by assuming the worst — and the allowlist is the user's tool for opting out when they know better.

## How to suppress false positives

There is no per-line suppression comment for this auditor (yet). The suppression mechanisms are:

1. **Refactor to remove the escape**, which is usually possible and produces better code.
2. **Add the receiving function to `allowedEscapeFunctions`** if you have documented its contract and verified it's pointer-safe.
3. **Move the allocation** so the pointer doesn't need to escape. For example, allocate with `UnsafeMutablePointer.allocate` and manage the lifetime explicitly (separately enforced by the `unmanaged-retain-leak` rule).

If you find yourself reaching for the allowlist on every file, or refactoring around the auditor in ways that hurt readability, the rule is probably miscalibrated for your codebase. Open an issue.
