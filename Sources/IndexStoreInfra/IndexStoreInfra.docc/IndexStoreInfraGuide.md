# IndexStoreInfra Guide

What IndexStoreInfra is, what it unlocks for quality-gate checkers, and how to build a cross-file analysis pass on top of it.

## The problem: single-file analysis hits a wall

Most quality-gate checkers walk each Swift file independently with SwiftSyntax. This works well for per-expression rules (force unwraps, FP equality, pointer escapes) but breaks down for anything that crosses file boundaries:

- **ConcurrencyAuditor** cannot verify that an `@unchecked Sendable` type's stored properties -- defined across multiple files via extensions -- are all Sendable.
- **RecursionAuditor** builds a call graph by matching function names, but overloaded functions with the same name produce false positives.
- **MemoryLifecycleGuard** flags `Task` properties without `deinit` cancellation, but the cancellation might live in an extension in another file.
- **DocCoverageChecker** flags undocumented protocol extension defaults even when the protocol requirement they satisfy is already documented.

These are not edge cases. In any codebase that uses extensions, protocols, or multiple modules, single-file analysis produces a steady stream of false positives (flagging correct code) and false negatives (missing real bugs).

## What IndexStoreDB provides

Apple's IndexStoreDB is the same index that powers Xcode's "Jump to Definition", "Find All References", and "Call Hierarchy" features. It is built as a side effect of every Swift compilation and contains:

- **Unified Symbol Resolutions (USRs)** -- globally unique identifiers for every symbol. Two functions with the same name but different parameter types have different USRs.
- **Occurrence records** -- every place a symbol appears, annotated with roles (definition, reference, call, read, write, override, base-of, conformance).
- **Relation records** -- edges between symbols: which function calls which, which type conforms to which protocol, which property overrides which protocol requirement.

This is the data that transforms heuristic analysis into precise analysis.

## IndexStoreInfra architecture

IndexStoreInfra wraps IndexStoreDB into five components, each solving one piece of the "find index, open it, query it" pipeline:

### ProjectKind -- what kind of project is this?

```swift
let kind = ProjectKind.detect(at: projectRoot)
switch kind {
case .swiftPM(let packageRoot):
    // auto-build to generate index store
case .xcode(let projectFile, let root):
    // look in ~/Library/Developer/Xcode/DerivedData
case .xcworkspace(let workspaceFile, let root):
    // same as .xcode but for workspaces
case .plain(let root):
    // no index available, syntactic-only
}
```

Detection is deterministic: `Package.swift` wins over `.xcworkspace` wins over `.xcodeproj` wins over plain directory. The result drives both where to look for the index store and how to enumerate source files.

### StoreLocator -- where is the index store?

```swift
let located = try StoreLocator.locate(projectKind: kind)
// located?.url     -- path to the index store directory
// located?.isStale -- true if sources are newer than the index
```

For SwiftPM packages, `StoreLocator.ensureFresh(packageRoot:)` builds an isolated index store at `.build/index-build/index-store` with the flags `swift build -Xswiftc -index-store-path`. This is idempotent and incremental -- rebuilds only what changed.

For Xcode projects, `StoreLocator.locateInDerivedData(projectName:projectPath:)` scans `~/Library/Developer/Xcode/DerivedData/` for matching entries, validates `info.plist` workspace paths, and picks the newest match by modification date.

Staleness checking compares the index store's modification time against the newest `.swift` file under the project root. A stale index means the code changed since the last build -- results may be incomplete but are never wrong (the index reflects the last-built state).

### IndexStoreSession -- open and query the index

```swift
let session = try IndexStoreSession(
    storePath: located.url,
    libPath: IndexStoreSession.findLibIndexStore()!
)
// session.db is a ready-to-query IndexStoreDB instance
```

IndexStoreSession handles the boilerplate: locating `libIndexStore.dylib` from the active toolchain, creating a temporary database directory, opening the index store, and polling for unit changes. The temporary database is cleaned up in `deinit`.

`findLibIndexStore()` searches three locations in order: the Xcode toolchain at `/Applications/Xcode.app/...`, the Command Line Tools at `/Library/Developer/CommandLineTools/...`, and the result of `xcrun --find swift` for custom toolchain installations.

### ConformanceQuery -- high-level cross-file queries

```swift
// Find all types conforming to a protocol
let conformers = ConformanceQuery.findConformers(
    ofProtocol: "AppIntent",
    in: session.db,
    limitToFiles: swiftFiles
)

// Find all references to a symbol by USR
let refs = ConformanceQuery.findReferences(
    toUSR: "s:10AppIntents0B6IntentP",
    in: session.db,
    roles: [.reference, .call]
)

// List all symbols defined in specific files
let symbols = ConformanceQuery.symbolsInFiles(
    swiftFiles,
    in: session.db
)
```

ConformanceQuery translates IndexStoreDB's low-level symbol occurrence API into domain-level questions: "which types conform to this protocol?", "where is this symbol used?", "what symbols exist in these files?" These are the building blocks that checkers compose into analysis passes.

### SourceWalker -- enumerate Swift files

```swift
let files = SourceWalker.swiftFiles(
    under: projectRoot,
    excludePatterns: ["**/Generated/**"]
)
```

SourceWalker recursively finds `.swift` files while skipping build artifacts (`.build`, `DerivedData`, `Pods`, `Carthage`), Xcode container packages (`.xcodeproj`, `.xcworkspace`), and user-configured exclude patterns. Every checker that needs "all Swift files in the project" should use this instead of rolling its own enumeration.

## Building a cross-file analysis pass

The established pattern for adding IndexStoreInfra to an existing checker is the **optional Pass 2** architecture, first implemented in UnreachableCodeAuditor:

### The dual-pass pattern

```
Pass 1 (Syntactic)          Pass 2 (Cross-module)
---------------------       -------------------------
Always runs                 Optional, requires index
Per-file SwiftSyntax        IndexStoreDB queries
Fast, zero-configuration    Adds ~200ms for index open
Produces diagnostics        Adds more diagnostics
```

Pass 1 is the existing checker logic, unchanged. Pass 2 runs after Pass 1, uses IndexStoreDB to answer cross-file questions, and adds new diagnostics that Pass 1 cannot detect. If the index is unavailable (plain project, no build, stale store), Pass 2 emits a `.note` explaining why it was skipped and the gate continues with Pass 1 results only.

### Graceful degradation

Pass 2 must never fail the gate when the index is unavailable. The contract:

| Scenario | Behavior |
|----------|----------|
| No index store found | Emit `.note`, skip Pass 2 |
| Index store is stale | Emit `.note`, run Pass 2 with caveat |
| `libIndexStore.dylib` not found | Emit `.note`, skip Pass 2 |
| IndexStoreDB throws on open | Emit `.note`, skip Pass 2 |
| Pass 2 query returns empty results | Normal -- no additional diagnostics |

The `SkipMarker.skipped` error pattern (used by UnreachableCodeAuditor) provides clean control flow:

```swift
do {
    let located = try StoreLocator.locate(projectKind: kind)
    guard let storeInfo = located else {
        diagnostics.append(Diagnostic(
            severity: .note,
            message: "Cross-file pass skipped: no index store available."
        ))
        throw SkipMarker.skipped
    }
    let session = try IndexStoreSession(
        storePath: storeInfo.url,
        libPath: try Self.locateLibIndexStore()
    )
    diagnostics += try MyIndexPass.run(session: session, ...)
} catch SkipMarker.skipped {
    // note already added
} catch {
    diagnostics.append(Diagnostic(
        severity: .note,
        message: "Cross-file pass skipped: \(error.localizedDescription)"
    ))
}
```

### Configuration toggle

Every checker's config struct gains a `useIndexStore: Bool` field (default `true`):

```yaml
# .quality-gate.yml
concurrency:
  useIndexStore: true    # default
recursion:
  useIndexStore: false   # disable cross-module for speed
```

When `false`, Pass 2 is skipped entirely -- no index location attempt, no `.note` diagnostic.

## What IndexStoreInfra unlocks for each checker

### ConcurrencyAuditor (Tier 1)

**Today:** Checks each file independently. Cannot verify that an `@unchecked Sendable` type's stored properties (defined across extensions in multiple files) are all Sendable-compatible.

**With Pass 2:**
- Detects stored properties added in extensions across files that violate Sendable
- Identifies `@unchecked Sendable` types that never actually cross an isolation boundary
- Verifies whether `@preconcurrency import` is needed by checking if imported symbols appear in Sendable-requiring contexts

### RecursionAuditor (Tier 1)

**Today:** Builds a call graph by matching `TypeName.methodName(label:)` strings. Overloaded functions with identical names but different parameter types create false-positive cycles.

**With Pass 2:**
- Replaces name-based matching with USR-based resolution -- two overloads get different USRs, eliminating false positives
- Detects mutual recursion cycles that cross module boundaries
- Catches protocol witness table recursion (a default implementation that dispatches back through the witness table)

### MemoryLifecycleGuard (Tier 2)

**Today:** Flags `Task` properties without `deinit` cancellation, but only checks the same file. Extensions in other files are invisible.

**With Pass 2:**
- Suppresses false positives when Task cancellation exists in a cross-file extension
- Detects delegate properties retained strongly in another file
- Suppresses false positives when AsyncStream termination is handled elsewhere

### DocCoverageChecker (Tier 2)

**Today:** Flags every public declaration without a `///` comment. Protocol extension defaults that inherit documentation from their protocol requirement are false positives.

**With Pass 2:**
- Detects inherited documentation through protocol-requirement relationships
- Ranks undocumented APIs by reference count so you know which to document first
- Reports both "explicit" and "effective" coverage percentages

### ComplexityAnalyzer (Tier 2)

**Today:** Builds an intra-module call graph via SwiftSyntax for complexity amplification. Cannot see call targets in other modules.

**With Pass 2:**
- Resolves cross-module call targets to compute amplified complexity across module boundaries
- A function with complexity 5 that calls a function in another module with complexity 20 reports amplified complexity of 25
- Uses USR-based resolution for intra-module calls too, matching the RecursionAuditor upgrade

## Performance characteristics

IndexStoreDB is designed for IDE-speed queries. Typical overhead for a quality-gate run:

| Operation | Time |
|-----------|------|
| `StoreLocator.locate()` | ~5ms (filesystem scan) |
| `IndexStoreSession.init()` | ~200ms (dylib load + DB open) |
| `ConformanceQuery.findConformers()` | ~1ms per protocol |
| `ConformanceQuery.findReferences()` | ~2ms per symbol |
| `SourceWalker.swiftFiles()` | ~10ms (filesystem walk) |

The IndexStoreSession should be created once and shared across all checkers that need it in a single gate run. The ~200ms cost is amortized across checkers.

For SwiftPM packages, `ensureFresh()` triggers an incremental build if sources changed. The first build may take 10-30s; subsequent incremental builds typically complete in 1-3s.

## Adding IndexStoreInfra to a new checker

1. Add `IndexStoreInfra` to your target's dependencies in `Package.swift`
2. Add `useIndexStore: Bool` to your config struct in `Configuration.swift`
3. Create a `*IndexPass.swift` file with a static `run(inputs:)` method
4. Wire it into your checker's `check()` method using the graceful degradation pattern
5. Add tests that cover both the Pass 2 logic and the "index unavailable" path
6. Run `swift run quality-gate` and verify 0/0
