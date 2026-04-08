# UnreachableCodeAuditor v6 — remaining items

**Status:** PLANNED · low priority (polish, no user-visible behavior change)

v6 #4 (auto-generated witness allow-list) is **done** and shipped — see
`scripts/regenerate-witnesses.sh`, `WellKnownWitnesses+{Curated,Generated}.swift`,
and `.github/workflows/regenerate-witnesses.yml`. The remaining three v6
items are pure internal cleanup; none of them change what the auditor
finds. Address them in response to a concrete need (a bug, a refactor, a
contributor confused by the current shape) rather than speculatively.

---

## v6 #1 — Self-audit cross-module via subprocess from `swift test`

**Goal:** make `SelfAuditTests` cover the cross-module pass, not just the
syntactic one. Today the cross-module self-audit lives in
`scripts/self-audit.sh` because running `swift build` recursively from
inside `swift test` deadlocks on SwiftPM's shared cache lock.

**Approach:** spawn the *release-built* `quality-gate` binary as a
subprocess from the test, in a process group that's isolated from the
parent `swift test`. The subprocess uses its own `--build-path
.build/index-build` so it doesn't fight with the outer test's debug
build state.

**Bootstrap:** the test depends on the release binary being present. If
it's missing, build it from inside the test as a fallback (or skip with
a clear `XCTSkipIf` and a note pointing at `make audit-self`).

**Estimated cost:** 1 session. Risk: bootstrapping the release binary
from inside `swift test` may hit the same lock the v5 work uncovered;
need to verify empirically.

**Deferred unless:** someone introduces cross-module dead code in a PR
that the in-process syntactic self-audit can't catch *and*
`scripts/self-audit.sh` isn't being run as part of CI. Right now the
shell script + the GitHub Actions workflow handle this.

---

## v6 #2 — `Strings.swift`-style "scaffold type" allow-list

**Goal:** suppress the noisy WineTaster pattern where a `Strings` /
`Constants` / `R.string` type holds dozens of `static let` values
referenced only by string-key lookups in views (e.g.
`Text(LocalizedStringKey("welcome"))` instead of
`Text(Strings.welcomeString)`). The auditor correctly finds these as
unreferenced — but spot-checking on WineTaster suggests this is an
acceptable false-positive class for many app codebases that drift
between literal strings and a typed scaffold.

**Approach:** add a config knob:

```yaml
unreachable:
  scaffoldTypeNames:
    - Strings
    - Constants
    - L10n
    - R.string
```

Any type whose name matches becomes a wholesale root: every member is
treated as live. Off by default. Documented as "use sparingly — this is
a scaffolding escape hatch, not a fix for missing reachability."

**Cost:** 1 session. Trivial change to the root-collection pass.

**Deferred unless:** you have a project where `Strings`-type findings
are the dominant class of false positives and you don't want to delete
the dead constants individually.

---

## v6 #3 — Read access level from IndexStoreDB instead of SwiftSyntax

**Goal:** drop the `DeclFactVisitor.isPublicOrOpen` reconstruction (and
its `publicProtocolDepth` patch for protocol members) by reading
accessibility directly from each `IndexStoreDB.Symbol`.

**Blocker:** as of the version of IndexStoreDB we use, `Symbol` does
**not** expose accessibility. There's a `SymbolProperty` enum but it
covers only `unitTest`, `ibAnnotated`, etc. — not `public`/`internal`/
`private`. SourceKit-LSP works around this by parsing the source itself
(the same approach we already use).

**Approach:** wait for IndexStoreDB to expose accessibility (likely
never — the right API is to use SourceKit-LSP). Until then, this item
is **NOT ACTIONABLE** and can be deleted from the v6 list.

**Status:** marked as **infeasible without an upstream change**.

---

## When to actually do v6 #1 and v6 #2

Both items are reactive, not proactive. Track them here so they're easy
to find when:

- A contributor asks "why doesn't `swift test` run the cross-module
  audit on this repo?" → do v6 #1.
- A WineTaster-class project shows up where the `Strings`-scaffold
  pattern dominates the noise → do v6 #2.

Until then, the auditor is in a steady state.
