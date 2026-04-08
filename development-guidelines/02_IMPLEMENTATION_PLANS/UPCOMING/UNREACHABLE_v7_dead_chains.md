# UnreachableCodeAuditor v7 — dead chains via reliable call graph

**Status:** PLANNED · medium priority (recall improvement)
**Estimated cost:** 1-3 sessions (depends on path chosen)
**Effect on findings:** ~10-30 additional findings on a WineTaster-sized
codebase, of which ~5-15 are independent regressions vs. tails of chains
whose head is already flagged.

---

## The problem v7 fixes

v3.1 introduced a **conservative final filter** in
`IndexStorePass.run`: a symbol is flagged only when *both*
1. it's not in the BFS reachable set, **and**
2. it has zero incoming references in the index.

This was added because the call-graph edges built from
`IndexStoreDB.SymbolOccurrence.relations` turned out to be unreliable
(see the v3 design doc for the war story — empirically, references in
real Swift code don't reliably set `.calledBy` / `.containedBy` /
`.childOf` the way the docs imply).

The cost: in a dead chain `A→B→C` where nothing calls `A`,
- v3.1 flags `A` (it has zero refs)
- v3.1 does **not** flag `B` (it has one ref — from A)
- v3.1 does **not** flag `C` (it has one ref — from B)

The user has to delete `A`, re-run the auditor, then delete `B`,
re-run, then `C`. v7's job is to drop the conservative filter so all
three fall in one pass.

---

## Why this is hard

The conservative filter can't be dropped until the call graph is
**reliable**. Today's graph is built by the v4 lexical-enclosing rewrite
in `IndexStorePass.run` pass 3:

```swift
for each reference occurrence in each file:
    let enclosingLine = liveness.enclosingDeclNameLine(file, line)
    if let usr = defByLocation[file]?[enclosingLine] {
        edges[usr, default: []].insert(referenced.usr)
    }
```

This works **most** of the time, but misses edges when:
- the reference is inside a property's getter/setter (the enclosing
  syntactic decl is the property, but its USR isn't in `defByLocation`)
- the reference is inside a default-argument expression
- the reference is inside a result builder closure
- the reference is inside a generic specialization
- path normalization between SwiftSyntax and IndexStoreDB drops a
  reference (we fixed several of these in v4 but more lurk)
- the SwiftSyntax visitor doesn't recognize the enclosing decl kind
  (we added `SubscriptDecl` in v5; macro-emitted decls are still gaps)

When the graph is incomplete, dropping the conservative filter would
flag every symbol whose incoming edge we missed. The v3 attempt produced
~50 false positives on quality-gate-swift itself.

---

## Three paths forward

### Path A — SourceKit-LSP integration *(highest fidelity, highest cost)*

Spawn `sourcekit-lsp` as a subprocess and use its
`textDocument/references` query. SourceKit-LSP's reference-finding is
the same code Xcode uses for "Find Call Hierarchy" — it's the gold
standard.

**Pros:**
- Authoritative call graph, dead chains drop out for free
- Same data Xcode uses, so users see consistent results
- Long-term durability (Apple maintains it)

**Cons:**
- Major new dependency (a process pipe protocol with lifecycle, schema
  versioning, and recovery from crashes)
- Slow startup (~2-5s per session)
- LSP schema drift across Swift toolchain releases
- Doesn't solve the "find every reference in the project" problem
  cleanly — LSP's `references` query is per-symbol, so you'd issue one
  per def, which is N² in the worst case

**Cost:** 3-5 sessions to get a working prototype, plus ongoing
maintenance for protocol drift.

### Path B — `IndexStoreDB.forEachSymbolOccurrence(...)` brute walk *(moderate cost)*

IndexStoreDB exposes a global `forEachSymbolOccurrence` iterator. We
can walk *every* occurrence in the index store once, and for each one
identify the enclosing symbol via either the existing lexical lookup
*or* a more careful walk of `relations`.

The key insight: a single global iteration is O(N) where N is the
total number of occurrences. For each occurrence we can apply *both*
the lexical-enclosing lookup and the relation-based lookup, take the
union, and feel more confident the edge is captured.

**Pros:**
- Stays inside our existing dependency (no new processes)
- Single global pass is faster than per-symbol queries
- Doesn't require rewriting the syntax visitor

**Cons:**
- Still heuristic — relations may still be missing
- Empirically unproven; we don't know how much it improves over v4

**Cost:** 1-2 sessions. Lower-risk than Path A.

### Path C — `swift-symbol-graph-extract`-driven static analysis *(narrowest scope)*

Use `swift symbolgraph-extract` (the same tool we already use for the
witness allow-list) to dump the project's own symbol graph. The graph
includes `relationships` of kinds `memberOf`, `inheritsFrom`,
`conformsTo` — and we can synthesize calls by walking the symbols
inside each function body.

**Pros:**
- Same dependency as v6 #4 — no new tooling
- Symbol graph is more stable than IndexStoreDB relations

**Cons:**
- Symbol graph doesn't have *call* relationships, only *containment*.
  Doesn't actually solve the dead-chain problem.
- Mostly redundant with what we already do.

**Cost:** sunk cost — won't buy us anything not already in v4.

---

## Recommendation

Try **Path B first**. It's the cheapest and exercises the existing code
path more aggressively. If after a real WineTaster test it still misses
edges, *then* commit to Path A. Don't speculate on Path A's cost-value
ratio without first proving Path B's ceiling.

## Test plan

Extend `CrossModuleFixture` with:
- A 4-link dead chain `D → E → F → G` (none reachable). v7 must flag
  all four.
- A 4-link live chain rooted at a public function. None flagged.
- A "diamond" graph: `A → {B, C}; B → D; C → D`. With `A` reachable,
  all four live; with `A` unreachable, all four flagged.

Add these as tests in `CrossModuleTests.swift` and update the existing
"flag head only" assertion to expect every link.

## Files

**New:** none (refactor in place)
**Modified:**
- `Sources/UnreachableCodeAuditor/IndexStorePass.swift` — drop the
  conservative final filter, broaden the edge-builder
- `Tests/UnreachableCodeAuditorTests/Fixtures/CrossModuleFixture/Sources/FixtureLib/Chains.swift`
- `Tests/UnreachableCodeAuditorTests/CrossModuleTests.swift`

## Risk

Medium. The v3 attempt at this exact change introduced false positives
that took two iterations to clean up. The mitigation is to keep the
conservative filter behind a config flag for the first release of v7
and gather real-world feedback before flipping the default.

```yaml
unreachable:
  reachabilityMode: "strict"   # v7 default — conservative filter on
  # reachabilityMode: "graph"  # opt in to full BFS
```

Promote `graph` to default when it's been clean on `quality-gate-swift`
self-audit for a release cycle.
