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
let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let kind = ProjectKind.detect(at: projectRoot)
let indexStrategy: String
switch kind {
case .swiftPM(let packageRoot):
    // auto-build to generate index store
    indexStrategy = "swift build -Xswiftc -index-store-path in \(packageRoot.path)"
case .xcode(let projectFile, let root):
    // look in ~/Library/Developer/Xcode/DerivedData
    indexStrategy = "DerivedData for \(projectFile.lastPathComponent) under \(root.path)"
case .xcworkspace(let workspaceFile, let root):
    // same as .xcode but for workspaces
    indexStrategy = "DerivedData for \(workspaceFile.lastPathComponent) under \(root.path)"
case .plain(let root):
    // no index available, syntactic-only
    indexStrategy = "syntactic-only for \(root.path)"
}
```

Detection is deterministic: `Package.swift` wins over `.xcworkspace` wins over `.xcodeproj` wins over plain directory. The result drives both where to look for the index store and how to enumerate source files.

### StoreLocator -- where is the index store?

```swift
var located: StoreLocator.LocatedStore?
do {
    located = try StoreLocator.locate(projectKind: kind)
} catch {
    located = nil
}
// located?.url     -- path to the index store directory
// located?.isStale -- true if sources are newer than the index
```

For SwiftPM packages, `StoreLocator.ensureFresh(packageRoot:)` builds an isolated index store at `.build/index-build/index-store` with the flags `swift build -Xswiftc -index-store-path`. This is idempotent and incremental -- rebuilds only what changed.

For Xcode projects, `StoreLocator.locateInDerivedData(projectName:projectPath:)` scans `~/Library/Developer/Xcode/DerivedData/` for matching entries, validates `info.plist` workspace paths, and picks the newest match by modification date.

### What the freshness check does and does not establish

There are two checks, and they answer different questions.

**The store as a whole** -- `IndexFreshness` compares the newest unit file with the newest `.swift` file under the project root. When the newest source is newer, the store is stale and a checker refuses to read it (`<checker>.index.stale-barrier`). When it is not, exactly one thing has been established: *a* build wrote *a* unit after the last edit. Nothing has been established about any other unit.

That matters because a build adds to an index store and nothing prunes it. A unit is named after the output path of the compilation that wrote it -- `QRCodeError.o-2EHOFO6YVTDTW` is the basename and a hash of `/Ignite.build/Debug/IgniteCLI-…-testable-t.build/Objects-normal/arm64/QRCodeError.o` -- so one source compiled for two build variants has two units, and a variant that stops being built leaves its units where they were. swiftbuild compiles an executable target twice whenever a test target imports it; when the import is removed, the `-testable` units stay behind, describing the source as it was at their last build. Ignite's store held a unit from 27 August beside that day's unit for the same file, reported "1m newer than the newest source", and yielded a finding for a symbol that had been deleted, at a line that held a different declaration.

Two properties of IndexStoreDB turn that leftover into a wrong answer:

- `symbols(inFilePath:)` reads **one** record for a file -- from whichever unit containing it the database enumerates first, which is decided by a hash of the unit's name. With a stale unit beside a fresh one, roughly half the time the symbol list is the stale one: deleted symbols are present and newly added ones are absent.
- `occurrences(ofUSR:roles:)` reads **every** unit. A symbol that moved is reported at both its old line and its new one.

And one property of the database makes removing the unit file insufficient: IndexStoreDB notices a removed unit only by comparing two scans made in the *same process*. A gate run makes one scan, so whatever an earlier run ingested from a unit stays in `quality-gate-indexdb-*` after the unit is gone.

**Each unit** -- so `IndexStoreSession` takes a census before it opens the database. `IndexUnitCurrency` reads every unit's main source file, output path, module and target, and gives each unit compiled from a source one of four verdicts:

| Verdict | Meaning | Read? |
|---------|---------|-------|
| current | written at or after its source's last modification, and the newest unit for its source, module and platform | yes |
| stale | its source was modified after it was written | no |
| superseded | a newer unit exists for the same source, module and platform | no |
| orphaned | its source file no longer exists | no |

The session then opens IndexStoreDB in explicit-output-units mode and declares only the current units. A unit that was not declared is not ingested, and -- if an earlier run already ingested it -- is not visible to any query. Nothing is deleted from the store or the database, the database layout is unchanged, and a database written before the census existed needs no migration. The census is on `IndexStoreSession.unitCensus`; `IndexFreshness.coverageNote(checkerId:census:)` renders it, so an `…index.age` note reads `… · 1716 units. 1264 compiled from source: 1254 read, 10 ignored (7 stale, 2 superseded, 1 orphaned).`

Setting a stale unit aside is free when a current unit for the same source remains. When none does, the source is listed in `IndexUnitCensus.sourcesWithoutCurrentUnit`, and that is a hole rather than clutter: the file's references are gone from the index along with its definitions, so whatever only that file calls would read as unreachable. A checker whose findings depend on references must refuse to run in that state (`IndexUnitCensus.undescribedSourcesBarrier`); `unreachable` does.

What this still cannot see:

- **It trusts modification times.** A file rewritten with identical content looks edited; a file edited while its own compilation was running can leave a unit dated after an edit it never saw.
- **It judges a unit by its main file alone.** A unit for `A.swift` is current if `A.swift` has not changed, even when a file it refers to has -- a build would have recompiled `A.swift` if the change mattered to it, but only in a variant that is still being built.
- **It cannot tell "no longer compiled" from "not compiled yet".** A source with only stale units is reported as undescribed either way. If the file left every target, the barrier persists until the leftover unit or the file is removed.
- **Platforms are told apart by triple, with the version dropped.** Units for iOS and macOS do not supersede each other, because each sees references the other's `#if os(…)` hides. Two units that differ in something the triple does not record -- a custom compilation condition -- are treated as one compilation, and the older is superseded.
- **A current unit is read whole.** `IndexedDeclaration.appears(indexedName:inSourceLine:)` is the last check a consumer can make before quoting the index: whether the recorded line still mentions the symbol. It is a minimum, and it is applied by each consumer, because only the consumer knows which occurrence it is about to turn into a finding. Today that is `unreachable` alone.
- **If the census cannot be taken** -- the unit reader is a second library, loaded separately -- the session reads every unit, `unitCensus` is `nil`, and the note says the units were not examined individually.

### IndexStoreSession -- open and query the index

```swift
var session: IndexStoreSession?
do {
    if let storeInfo = located, let libPath = IndexStoreSession.findLibIndexStore() {
        session = try await IndexStoreSession(
            storePath: storeInfo.url,
            libPath: libPath
        )
    }
} catch {
    session = nil
}
// session?.db is a ready-to-query IndexStoreDB instance
```

IndexStoreSession handles the boilerplate: locating `libIndexStore.dylib` from the active toolchain, taking the unit census described above, and opening the index store against a persistent database beside it (`quality-gate-indexdb-<store name>`), so a later run registers only the units that changed. The initializer is `async` because the census is; there is deliberately no synchronous overload, which would open the store without one. The database is a cache of the store and is safe to delete at any time.

`findLibIndexStore()` searches three locations in order: the Xcode toolchain at `/Applications/Xcode.app/...`, the Command Line Tools at `/Library/Developer/CommandLineTools/...`, and the result of `xcrun --find swift` for custom toolchain installations.

### ConformanceQuery -- high-level cross-file queries

```swift
let swiftFiles = SourceWalker.swiftFiles(under: projectRoot)
var querySummary = "index unavailable"

if let openSession = session {
    // Find all types conforming to a protocol
    let conformers = ConformanceQuery.findConformers(
        ofProtocol: "AppIntent",
        in: openSession,
        limitToFiles: Set(swiftFiles)
    )

    // Find all references to a symbol by USR
    let refs = ConformanceQuery.findReferences(
        toUSR: "s:10AppIntents0B6IntentP",
        in: openSession,
        roles: [.reference, .call]
    )

    // List all symbols defined in specific files
    let symbols = ConformanceQuery.symbolsInFiles(
        swiftFiles,
        in: openSession
    )

    querySummary = "\(conformers.count) conformers, \(refs.count) references, \(symbols.count) symbols"
}
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
| Index store is stale | Refuse Pass 2 and say why -- a stale index is not incomplete, it is wrong about lines and names |
| A source has units, none current | The same refusal, per file -- see *What the freshness check does and does not establish* |
| `libIndexStore.dylib` not found | Emit `.note`, skip Pass 2 |
| IndexStoreDB throws on open | Emit `.note`, skip Pass 2 |
| Pass 2 query returns empty results | Normal -- no additional diagnostics |

The `SkipMarker.skipped` error pattern (used by UnreachableCodeAuditor) provides clean control flow:

```swift
import QualityGateCore

enum SkipMarker: Error { case skipped }

enum MyIndexPass {
    static func run(session: IndexStoreSession, files: [String]) throws -> [Diagnostic] {
        ConformanceQuery.symbolsInFiles(files, in: session).map { entry in
            Diagnostic(
                severity: .note,
                message: "Cross-file symbol: \(entry.symbol.name)",
                ruleId: "my-checker.cross-file"
            )
        }
    }
}

func locateLibIndexStore() throws -> URL {
    guard let path = IndexStoreSession.findLibIndexStore() else {
        throw SkipMarker.skipped
    }
    return path
}

var diagnostics: [Diagnostic] = []
do {
    let storeLocation = try StoreLocator.locate(projectKind: kind)
    guard let storeInfo = storeLocation else {
        diagnostics.append(Diagnostic(
            severity: .note,
            message: "Cross-file pass skipped: no index store available."
        ))
        throw SkipMarker.skipped
    }
    let indexSession = try await IndexStoreSession(
        storePath: storeInfo.url,
        libPath: try locateLibIndexStore()
    )
    diagnostics += try MyIndexPass.run(session: indexSession, files: swiftFiles)
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
| `IndexStoreSession.init()` | ~0.3s warm on a 2,800-unit store: unit census ~0.1s, registering current units ~0.2s. Cold (no database yet) is a full ingest, seconds |
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
