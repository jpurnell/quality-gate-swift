# ``PointerEscapeAuditor``

Catches `Unsafe*Pointer` values that escape the `withUnsafe*` closure scope that owns their underlying memory.

## Overview

PointerEscapeAuditor was motivated by a real Accelerate FFT incident: a backend stored a pointer borrowed from `withUnsafeBufferPointer` and used it after the closure returned, producing intermittent memory corruption. The code compiled cleanly because Swift's safety net stops at the closure boundary.

This auditor walks every `withUnsafe*` call site in the file, tracks the closure parameter (`$0`, named, or tuple-destructured), and checks for nine kinds of escape patterns. It is intra-file and AST-only — no successful build or IndexStore required.

### Detected rules

| Rule ID | Severity | What it catches |
|---------|----------|-----------------|
| `pointer-escape.return-from-with-block` | error | Returning a tracked pointer from the closure (direct, derived, wrapped, or branched) |
| `pointer-escape.assigned-to-outer-capture` | error | Assigning a tracked pointer to an outer var, global, or static property |
| `pointer-escape.stored-in-property` | error | Assigning a tracked pointer to `self.x` |
| `pointer-escape.appended-to-outer-collection` | error | `outerArray.append(ptr)` or `outerArray.insert(ptr, at:)` |
| `pointer-escape.passed-as-inout` | error | Passing a tracked pointer to a non-allowlisted function call |
| `pointer-escape.stored-closure-captures-pointer` | error | A closure literal that captures a tracked pointer and is stored or returned |
| `pointer-escape.captured-by-escaping-closure` | warning | A tracked pointer captured inside a `Task { … }` or `DispatchQueue.async { … }` closure |
| `pointer-escape.unmanaged-retain-leak` | warning | `Unmanaged.passRetained(...).toOpaque()` stored without a matching `.release()` |
| `pointer-escape.opaque-roundtrip` | warning | Round-tripping a pointer through `OpaquePointer` outside the with-block |

### Pointer identity tracking

A tracked "pointer expression" is one of:

- A bare reference to the bound parameter name (`$0`, `ptr`, etc.)
- `<tracked>.baseAddress`, `<tracked>.advanced(by:)`
- `<tracked> + n`, `<tracked> - n`
- A struct/tuple/array/dictionary literal containing a tracked expression
- An `Any` cast wrapping a tracked expression
- A ternary branch where one side is tracked
- A local `let` alias (`let alias = ptr`) of a tracked expression

The auditor specifically does **not** treat these as pointers (they're values):

- `<tracked>.pointee`
- `<tracked>.first`, `.last`, `.count`, `.isEmpty`
- `<tracked>.reduce(...)`, `.map`, `.filter`, `.forEach`, `.compactMap`

### Nested with-blocks

The auditor maintains a stack of pointer scopes. When an inner `withUnsafe*` call appears inside an outer one, both bound names are tracked simultaneously. Returning the *outer* pointer from inside the *inner* closure is detected as an escape.

```swift
withUnsafePointer(to: x) { outer in
    withUnsafePointer(to: y) { inner in
        return outer   // ← flagged: outer escapes
    }
}
```

### Shadowing

If a closure body declares a new variable that shadows the bound parameter, the inner binding is not a tracked pointer:

```swift
withUnsafePointer(to: x) { ptr in
    let ptr = 5      // shadows the parameter
    print(ptr)       // not flagged — ptr is now an Int
}
```

### Allowlist

Some Apple APIs (notably parts of vDSP and `CFData.getBytePtr`) intentionally accept pointers that outlive the with-block via documented contract. Rather than ship a global allowlist that drifts, the auditor accepts a user-supplied set:

```swift
let auditor = PointerEscapeAuditor(
    allowedEscapeFunctions: ["vDSP_fft_zip", "vDSP_fft_zop"]
)
```

A function call to any allowlisted name fully suppresses pointer-escape diagnostics for that call site, including the implicit-return form.

### Conservative fallback

The "passed-as-inout" rule has a deliberately broad fallback: any non-allowlisted function call that receives a tracked pointer as a positional argument is flagged. This catches cases like `store(ptr)` where `store` internally assigns to a global, without requiring the auditor to perform interprocedural analysis. The escape hatch is the allowlist.

If this produces too many false positives in practice, it should be retuned — but the underlying assumption is that unknown function contracts cannot be assumed pointer-safe.

### Out of scope

- Interprocedural escape analysis (would require IndexStore + call graph)
- Cross-file pointer flow
- C-interop pointer flow into untyped C functions
- Default-argument capture (`func store(p: UnsafePointer<Int> = ptr) { … }`)
- `withExtendedLifetime` misuse

## Topics

### Essentials

- ``PointerEscapeAuditor/check(configuration:)``
- ``PointerEscapeAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:PointerEscapeAuditorGuide>
