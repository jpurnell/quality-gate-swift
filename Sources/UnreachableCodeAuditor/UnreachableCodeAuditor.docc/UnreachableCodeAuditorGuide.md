# UnreachableCodeAuditor Guide

Why dead code matters, how each rule works, and how to handle false positives in a multi-pass reachability analysis.

## Why this auditor exists

Dead code is not a cosmetic problem. It imposes ongoing maintenance cost (every refactor must avoid breaking it, every reviewer must decide whether to touch it), it obscures the actual program surface (new contributors read code that will never execute), and it hides latent bugs (a "dead" path that is reachable under an edge condition you forgot about).

Compilers catch some dead code. The Swift compiler warns on code after an unconditional return in simple cases. But it does not catch private functions never called, constant-condition branches left from debugging, or whole-program dead symbols that lost their last caller three pull requests ago.

UnreachableCodeAuditor fills these gaps with two analysis strategies:

1. **Syntactic pass** -- fast, zero-configuration, no build required. Catches post-terminator statements, constant-condition branches, and unused private symbols within a single file.
2. **Cross-module pass** -- uses IndexStoreDB to build a call graph across the entire project and BFS-walks it from a conservative root set. Catches functions, methods, properties, and enum cases that are structurally unreachable from any entry point.

## Rule walkthrough

### `unreachable.after_terminator`

Code after an unconditional terminator will never execute. The terminator set is: `return`, `throw`, `break`, `continue`, `fatalError()`, `preconditionFailure()`.

```swift
// flagged
func example() -> Int {
    return 42
    print("this never runs")   // unreachable.after_terminator
}

// flagged
func fail() {
    fatalError("done")
    cleanup()                  // unreachable.after_terminator
}

// accepted -- conditional return does not terminate
func example2(_ flag: Bool) -> Int {
    if flag { return 1 }
    return 2
}
```

The auditor flags the first unreachable statement in a block, not every subsequent one. The suggested fix is to remove the unreachable statements or restructure the control flow.

### `unreachable.dead_branch`

A branch guarded by a boolean literal is dead code left from debugging or feature-flag scaffolding that was never cleaned up.

```swift
// flagged -- then-branch is dead
if false {
    doSomething()              // unreachable.dead_branch
}

// flagged -- else-branch is dead
if true {
    doSomething()
} else {
    doOtherThing()             // unreachable.dead_branch
}

// accepted -- runtime condition
if isDebugMode {
    doSomething()
}
```

The auditor checks only the first condition in an `if` statement. Chained conditions (`if true && someCondition`) are not simplified -- only bare `true`/`false` literals are caught.

### `unreachable.unused_private`

A `private` or `fileprivate` symbol that is never referenced anywhere in the same file is unreachable by definition (no other file can see it).

```swift
// flagged
private func helperThatNobodyCalls() { }   // unreachable.unused_private

// accepted -- referenced elsewhere in the file
private func helper() -> Int { 42 }
let x = helper()

// accepted -- internal visibility (other files can reach it)
func notPrivate() { }
```

This rule fires at warning severity rather than error because it is a single-file heuristic. The symbol might be referenced through a protocol witness or dynamic dispatch path that the syntactic pass cannot see. The cross-module pass covers those cases more precisely.

### `unreachable.cross_module.unreachable_from_entry`

The headline rule. A symbol is flagged when it fails both gates:

1. BFS from the root set does not reach it.
2. The index contains zero reference/call/read/write occurrences of its USR outside its own definition line.

```swift
// flagged -- internal function never called from anywhere
func orphanedHelper() -> Int { 42 }   // unreachable.cross_module.unreachable_from_entry

// accepted -- called from a public entry point
public func api() -> Int { orphanedHelper() }
func orphanedHelper() -> Int { 42 }

// accepted -- protocol witness (overrideOf relation in index)
struct MyView: View {
    var body: some View { Text("hi") }
}
```

The suggested fix is to remove the symbol or mark it with `// LIVE:` if it is invoked dynamically (Objective-C runtime, reflection, external tooling).

### `unreachable.cross_module.skipped` and `unreachable.cross_module.stale`

These are informational notes, not errors. They tell you why the cross-module pass did not run or may have incomplete results.

```
note: Cross-module pass skipped: no index store available.
      (For Xcode projects, build in Xcode first or set
      `unreachableAutoBuildXcode: true`.)

note: Index store at /path/to/DataStore is older than the newest
      source file -- results may be out of date. Build the project
      in Xcode and re-run, or pass `--auto-build-xcode`.
```

The gate never fails purely on these notes. They exist so you know when you are running on syntactic-only results.

## The root set in detail

The cross-module pass must know what is "alive by definition" before it can identify what is dead. Getting the root set wrong in either direction produces either false positives (flagging live code) or false negatives (missing dead code). The auditor errs heavily toward false negatives -- if there is any doubt, the symbol is rooted.

**Public/open API in library targets.** A library's exported surface is reachable by any downstream consumer. The auditor queries `swift package describe --type json` (SwiftPM) or uses a suffix heuristic (Xcode) to determine target types. Modules whose type cannot be determined default to `"library"` -- the safe non-flagging default.

**Test targets.** Every symbol in a test target is rooted because the test runner is the implicit entry point. Target type is determined by the SwiftPM manifest or by a `Tests`/`UITests` module-name suffix heuristic.

**Protocol witnesses.** This is the most involved root category. Three mechanisms cover it:

1. IndexStoreDB's `overrideOf`/`baseOf` relations (reliable for user-defined protocols within the same project).
2. The hand-curated `WellKnownWitnesses.curated` set (operators `==`, `<`, etc. and conventional names like `body`).
3. The auto-generated `WellKnownWitnesses.generated` set (1860+ requirement names across 378 Apple framework protocols, extracted from Swift toolchain symbol graphs and regenerated weekly by CI).

**`// LIVE:` exemptions.** The user's escape hatch for any symbol the auditor cannot statically prove is live.

## False positives and how to suppress them

### The `// LIVE:` comment

Place a `// LIVE:` comment on the declaration line or the line immediately above it. The colon is required. Both of these work:

```swift
// LIVE: called via Objective-C runtime
func dynamicHelper() { }

func dynamicHelper() { } // LIVE: reflection target
```

The comment is detected by raw line scanning, not syntax-tree attachment, so it works regardless of surrounding whitespace or other comments on the same line.

### Macro-generated symbols

Symbols generated by Swift macros (`@Observable`, `@Model`, etc.) produce index entries that look like user-written code but cannot be removed. The auditor silently filters these by name pattern:

- Names starting with `_$` (e.g. `_$observationRegistrar`)
- Names starting with `_` followed by a letter (e.g. `_name`, `_id`)
- Names containing `:` without `()` (macro-generated memberwise inits)
- Specific known names like `withMutation(keyPath:_:)` and `access(keyPath:)`

If a macro-generated symbol slips through the filter, file an issue -- the pattern table should be extended rather than worked around with `// LIVE:`.

### Initializers and CodingKeys

Initializers are conservatively rooted because the auditor does not yet model type-level reachability (whether the type itself is instantiated). `CodingKey` enum cases are rooted because the compiler-synthesized `Codable` machinery that calls them is invisible to the index. Neither category should produce false positives.

### When the cross-module pass disagrees with reality

The conservative double-gate (BFS unreachable *and* zero index references) means the cross-module pass will only flag a symbol if both analyses agree it is dead. Common scenarios where the pass might still be wrong:

- **Dynamic dispatch not visible to the index.** Objective-C selectors invoked via `perform(_:)`, `NSInvocation`, or `#selector` where the index does not record a reference. Fix: add `// LIVE:` or ensure `@objc` is present (which roots the symbol automatically).
- **Cross-module references from outside the project.** If another project depends on this one as a package dependency, internal symbols it calls are not in this project's index. Fix: those symbols should be `public` (which roots them) or the downstream project should be included in the analysis root.
- **Stale index store.** If you changed code but did not rebuild, the index reflects the old call graph. The auditor emits a `unreachable.cross_module.stale` note when it detects this, but cannot fix it for you. Fix: rebuild and re-run.

### Project-specific configuration

For Xcode projects that do not have a recent build, set `unreachableAutoBuildXcode: true` in `.quality-gate.yml` (or pass `--auto-build-xcode` on the CLI) to let the auditor drive `xcodebuild build` automatically. This is opt-in because it is slow and has filesystem side effects.

```yaml
# .quality-gate.yml
unreachableAutoBuildXcode: true
xcodeScheme: MyApp           # optional, auto-detected if omitted
xcodeDestination: "generic/platform=iOS"  # optional, defaults to macOS
```

For SwiftPM packages, no configuration is needed -- the auditor builds an isolated index store into `.build/index-build/` automatically.
