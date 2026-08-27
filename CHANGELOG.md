# Changelog

## [Unreleased]

### Changed

- **`ProcessRunner` moved to [`swift-process-kernel`](https://github.com/jpurnell/swift-process-kernel)
  and is re-exported from `QualityGateCore`.** Nothing about it was
  quality-gate-specific: it answers a Foundation problem, in that `Process` offers
  three ways to wait forever and production code finds all of them.

  It moved because it could not be shared. Anything wanting the runner had to depend
  on the whole gate, and this package depends on `swift-vigil` — so vigil adopting it
  would have closed a dependency cycle. `bounded-io` was therefore unsatisfiable in
  that repository: the rule's own suggested fix named a symbol vigil could not import,
  and writing the correct fix did not clear the rule. That is the same failure the
  `kernelPath` work already fixed once for foreign repositories, appearing again from
  the other direction — a repository the gate *depends on* rather than one it audits.

  No call site changed. The 23 sites across 18 targets still say `ProcessRunner.run(…)`
  and reach it through `QualityGateCore` as before, via `@_exported import` — the
  pattern this package already uses in five places. Naming the dependency in each
  target would have been 18 `Package.swift` edits to relocate a symbol none of them
  chose the home of.

  `ProcessRunnerDeadlineTests` and `ProcessRunnerStdinTests` moved with it, so the
  corpus of hang variants lives beside the code it constrains and there is no second
  copy to drift. Verbatim apart from the timeout notice appended to stderr, which said
  `quality-gate:` and is now `process-kernel:`.

  **`BoundedIOAuditor.defaultKernelPath` is now vestigial** and matches no file in any
  repository, this one included. A repository whose spawns all route through the shared
  runner has no in-tree kernel and correctly needs none — its unbounded primitives are
  *absent* rather than *contained*, which is the stronger property. Whether a
  per-repository kernel is still the right shape, or the rule is now simply "call the
  package", is left open rather than guessed at: changing that default changes the
  verdict for every repository the gate audits. The constant's documentation now says
  so instead of claiming, untruthfully, that it names this package's own type.

### Fixed (self-audit)

- **`security.ssrf` reported a URL built entirely from a same-file constant.**
  `URL(string: "https://\(Self.allowedHost)/lcdb")`, where `allowedHost` is a
  `static let` holding a string literal, has no dynamic input in it — and the suggested
  remedy, *validate against an allowlist of expected hosts*, cannot be applied to a value
  that is already a literal. The finding was unactionable as well as untrue.

  A literal whose every interpolation resolves to a `let` declared in the same file with a
  plain string-literal initialiser is now treated like the non-interpolated literal the
  rule already accepted.

  **The exemption is deliberately narrower than the a11y and HIG ones fixed alongside it.**
  Those turned on facts visible in the expression itself — an implicit member access with
  no base, a literal `.none` argument, a sibling modifier in the same chain. This one needs
  to know what an *identifier means*, and a security rule that guesses in the permissive
  direction is worse than one that occasionally over-reports. So it fails closed: a `var`,
  a function parameter, a computed property, a name declared in another file, a constant
  built from its own interpolation, or a URL where only some segments are constant all stay
  flagged. Seven tests, five of them guarding exactly those cases.

- **A replayed result now leads with its provenance instead of trailing it.** The
  `Replayed from cache` notice was appended, so it rendered *after* the diagnostics it
  qualifies — the last line of a block whose opening lines read as fresh findings. It is
  now the first diagnostic, and it names the run it is replaying:

      ℹ️  note: Replayed from cache: this checker did not run (produced 2026-08-26 21:37:48 UTC).
                Every finding below is from that run, as are any coverage or timing figures.

  The timestamp comes from the cache entry's modification time, since `CheckResult`
  records a duration but not a date, and is formatted in UTC under a POSIX locale so the
  line compares cleanly across machines and logs.

  This is the counterpart to the caching fix above rather than a cosmetic one. Both
  substantive bugs found that day — a cached failure replaying forever, and the release
  preflight reporting the CLI's own version as the surveyed project's — presented as a
  confident, specific, wrong statement, and in both cases the tool held what it needed to
  say something true. Placing that below three red errors put the one line that explains
  them where it would be read last, or filtered out entirely by a grep for `error:`.

- **A cached failure replayed forever, wedging commit retries.** `evaluate` stored every
  result regardless of status and replayed every result regardless of status. One
  contended run — a `swift test` starved by builds in three other repos — produced three
  real `DocCodeAuditor` failures, and the gate cached them. Every subsequent run replayed
  that verdict without executing anything, and the repo's pre-commit and pre-push hooks
  stayed blocked. `--no-cache` runs of the same checker passed in 167s throughout.

  The trap is specific and worth naming: the fingerprint holds only while the tree is
  unchanged, and **retrying a blocked commit is the one workflow that re-presents an
  identical tree on purpose**. Any real edit rotates the fingerprint and forces a genuine
  re-run, so a poisoned entry is invisible during ordinary development and bites exactly
  when someone is trying to get unstuck — and is least inclined to doubt a red result.
  Deterministic replay of one bad result is indistinguishable from a deterministic bug.

  A failure is now never replayed and is evicted when read, and never stored. The
  asymmetry is the point: a pass is a claim about the source, and this project already
  enforces the invariants that make replaying one safe — `TemporalDeterminismAuditor`
  forbids wall-clock nondeterminism, `StochasticDeterminismAuditor` forbids unseeded
  randomness. None of that covers a failure, which can come from contention, a killed
  subprocess, an OOM or a codesign hiccup. Passes and warnings stay cached, so the speed
  benefit is untouched; the only cost is re-running a checker that just failed, paid
  exactly when ground truth is wanted instead of a replay.

  Evicting **on read** rather than only guarding the write is what fixes caches that are
  already broken — there were 166 stored failures across 26 repos on the machine where
  this was found (thanks to the IconquerMatch session for measuring that, and for the
  commit-retry framing). A store-side guard alone is forward-only. Entries whose
  fingerprint never recurs stay on disk but are inert; the ones that would have replayed
  are now evicted on contact.

- **Five rules fired on code they do not apply to.** Each was reported as a real finding
  against a shipping app, and each asked for a change that would make the code worse.

  `hig.settings-scene` / `hig.menu-commands` resolved platform once per project from
  `Package.swift`; a repo with no manifest at its root — an Xcode project, or a monorepo
  of packages — fell back to `.all`, which contains macOS. A watchOS app was told to add
  a `Settings` scene, which is macOS-only and would not compile there. `auditSource` now
  prefers a platform the file states about itself (`PlatformDetector.detectAppPlatform`),
  using only markers that cannot appear elsewhere — WatchKit, `ImmersiveSpace`, AppKit,
  ActivityKit, `os(…)` conditionals. A file with no marker keeps the old behaviour.

  `a11y.missing-reduce-motion` matched every member access named `animation`.
  `TimelineView(.animation(minimumInterval:))` is a schedule — a render clock — and
  gating one on Reduce Motion stops the view updating at all; it is an implicit member
  expression, so it has no base where a modifier always does. `.animation(.none, …)` is
  already the reduced-motion outcome.

  `a11y.hardcoded-color-string` reported `Color(hex: someProperty)`. That value is chosen
  at runtime and there is no literal for the suggested fix to replace; a component must
  now be a literal.

  `a11y.color-only-differentiation` reported a glyph that changed colour *and* opacity on
  the same condition. A sibling modifier in the chain that varies and changes something
  other than colour — opacity, weight, symbol variant, or the `Image(systemName:)` itself
  — is the companion the rule asks for, and the one a colour-blind user can see.

  `a11y.standard-shortcut-override` flagged Command-comma bound inside
  `CommandGroup(replacing: .appSettings)`. The accommodation already existed for
  `newItem`/`saveItem`/`printItem`/`undoRedo`/`pasteboard`; `appSettings` was simply
  missing from the placement map, so adopting the system convention read as repurposing it.

  13 new tests, each pairing the false positive with a regression guard proving the true
  positive still fires. Found by driving a real app (harbor) to zero: of its 30 warnings,
  11 were these false positives, and two portfolio-wide clusters — 439 colour-only and 147
  hardcoded-colour occurrences across 74 projects — were this imprecision multiplied, not
  debt. The institutional consistency score moved 0.00 → 1.00.

- **`quality-gate release` reported its own version as the surveyed project's.**
  `Release.swift` passed `QualityGateCLI.configuration.version` as `declaredVersion`, so
  every package the preflight was ever run against was told *"the CLI reports version
  3.1.0"* — quality-gate's number, stated as a fact about someone else's release. Every
  other input in that command is read from the surveyed tree; this one input was not.
  Reproduced in two unrelated library packages, which were each told the same 3.1.0.

  The finding was not merely noisy, it was unactionable: its remedy said *"set the declared
  version to X"*, and a library that declares no CLI version has nothing to set. A rule
  whose remedy cannot be performed teaches people to ignore the rule.

  `ReleasePreflight.versionParity(declaredVersion:)` now takes `String?`, where `nil` means
  the project declares no version and there is therefore no disagreement to report — the
  tag check beside it still runs. `Release.swift` reads the version from the surveyed tree
  via the new `ReleasePreflight.declaredVersion(inProjectAt:)`, which scans `Sources/` for
  the `version: "X.Y.Z"` / `version = "X.Y.Z"` literal that both a `CommandConfiguration`
  and a `static let` take. Running the gate on itself still resolves 3.1.0, now by reading
  its own source rather than by being handed it.

  `ReleaseReadinessAuditor.scanForVersionInSources` now delegates to that same function
  instead of keeping a second copy of the heuristic — two copies of "what version does this
  project declare?" drifting apart is precisely the failure this rule exists to catch.

- **`DocLinter.docc` was excluded from its own target, so `doc-lint` had never once read
  the article it ships.** `exclude:` does not mean "don't build this" — it removes the path
  from the target's `sourceFiles`, and `sourceFiles` is exactly where swift-docc-plugin
  looks for a catalogue (`SourceModuleTarget.doccCatalogPath`). DocC was still handed the
  target and still linted its in-source `///` comments, so the check went green; the
  landing page was simply never opened. The exclusion arrived in ad1fca5 as a side note to
  an unrelated rule change — *"Also excludes .docc catalogs from all targets to eliminate
  54 SPM warnings"* — which is the shape of the problem: the warning was real (SwiftPM's
  native build system has no rule for `.docc` and calls it unhandled), and it was answered
  by hiding the file rather than declaring it.

  `DocLinter` now declares the catalogue as `resources: [.copy("DocLinter.docc")]`.
  SwiftPM treats it as handled, so the unhandled-file warning is gone for real, and the
  catalogue stays in `sourceFiles` where the plugin can find it. Verified by generating the
  archive and confirming the landing page's prose is in `doclinter.json` — not by trusting
  a green check, which is what produced this in the first place.

  With the article live, two defects in it surfaced immediately:

  - The **"Exit Codes" table** described behaviour the checker does not have — it claimed
    exit 1 meant "documentation has warnings (configurable)" and exit 2 meant errors.
    `createResult(output:exitCode:duration:)` fails on a non-zero build exit *or* any
    error-severity diagnostic, and warnings never fail on their own. Replaced with a
    **Verdict** section stating the actual rule, plus a **Target Selection** section
    covering the every-catalogue-owning-target default and the `docTarget` narrowing, which
    the article predated.
  - A symbol link written against the module page (`` `createResult(...)` `` rather than
    `` `DocLinter/createResult(...)` ``) resolved to nothing. DocC caught it on the first
    build after the change — the first time this catalogue had ever been checked.

  **34 other targets still carry the same exclusion** and are still unlinted articles. Same
  one-line fix each; not swept here.

### Fixed (checker correctness)

- **`accessibility`'s CLI rules audited the files that assert on escape sequences and never
  the files that write them.** `FrontendResolver` selected the `.cli` frontend by *import*,
  and a terminal toolkit never imports itself — its own sources are the module. So the
  detector ran over every consumer of `SwiftCLIKit`/`ArgumentParser`, which in practice
  means the toolkit's test target, and never over the toolkit. On SwiftCLIKit that was 9
  warnings, all of them `#expect(x == "ESC[31m")` in tests, while
  `AlternateScreen.writeEscape("ESC[?1049h")` — an unguarded `write(2)` to a raw file
  descriptor, exactly what `a11y.cli.cursor-control-no-tty` exists to catch — was invisible.
  Four things were wrong and all four are fixed:

  - `FrontendResolver.resolve(importedModules:declaringModule:)` now considers the module a
    file *belongs to* alongside the ones it imports, so a CLI toolkit audits itself. The new
    parameter defaults to `nil`, leaving import-only resolution unchanged for every other
    caller.
  - `AccessibilityAuditor` skips test targets. A test asserting that a widget produces
    `ESC[31m` is not a program writing `ESC[31m` to anyone's terminal. Resolved through the
    existing `TargetTypeMap`, which gained `target(forFile:)` — the lookup behind
    `targetType(forFile:)`, exposed because the module *name* was needed too, and because a
    caller sometimes needs to tell a miss from a match rather than read it strictly.
  - `honorsColorPreference` matched its markers as bare substrings, so `TERM` matched the
    word `TERMINAL` and any file mentioning a terminal in a doc comment silently switched
    off all three `a11y.cli.*` rules for its whole length — the rule was defeated by prose
    about the thing it audits. Markers now match at identifier boundaries. This costs the
    compound spellings (`noColorFlag` alone no longer registers), which is the intended
    direction: a marker that costs nothing to trip cannot be told apart from a decision.
  - All three rules now fire only on literals that **reach output**, walked up the ancestor
    chain to a call that writes. A constant naming an escape, or a function returning one,
    emits nothing — the caller decides whether to write it and whether to gate that on the
    user's preference. Without this every terminal library was a wall of findings for having
    a vocabulary. The walk is syntactic and stops there: a literal assigned to a variable and
    printed three statements later is not followed, because that is dataflow and this is a
    linter. The missed case is the quieter of the two failures, and it was the opposite
    error — treating every literal as output — that made these rules unusable.

  Net on SwiftCLIKit: 9 findings, 0 of them real → 1 finding, and it was a genuine bug.

### Added

- `AccessibilityCLITests`, covering the CLI detector's marker matching and its notion of
  emission. The detector had no tests of its own; the SwiftUI detector's suite was the only
  thing exercising the auditor.

## [3.1.0] — 2026-08-25

The gate stops paying for, and stops hiding, its own runs: index ingestion is paid once
instead of per run, a truncated run is reported as truncated, and the recursion survey's
22-package corpus reaches **zero errors** (from 174 errors / 279 warnings at its start).

### Fixed (checker correctness)

- **`recursion`'s superseded set is derived, not maintained — Pass 1's verdicts are
  provisional by construction wherever the index can answer.** The hand-kept
  `supersededByUSR` list grew twice in one session, each time *after* a false positive
  shipped in the wild, and five rules it never gained (`computed-property-self`,
  `setter-self`, `subscript-self`, `subscript-setter-self`, `convenience-init-self`) still
  carried final syntactic verdicts in indexed projects — the same latent defect, waiting
  for a package to trigger it. Probes showed the index already answers all five: accessors
  are indexed as callable `getter:x`/`setter:x` methods, and a self-recursive initializer
  carries a `calledBy` self-edge the graph simply never admitted (`isCallable` now accepts
  `constructor`; `analyzeInitializer` now records a `DeclarationInfo` so inits join the
  site handoff). Pass 2 classifies a self-edge by the index's symbol naming and reports in
  Pass 1's rule vocabulary at Pass 1's severities, and the superseded set is derived from
  that classifier — the next rule Pass 2 learns to answer joins it by construction. This
  also removes an incoherence: a genuine getter self-reference in a covered file
  previously produced *two* findings for one defect (Pass 1's error and Pass 2's generic
  warning). Corpus: zero movement, including SwiftyJSON's five overloaded subscripts.
  Design and probe data: `project/plans/proposals/ProvisionalByConstruction.md`.

- **`recursion` no longer inherits a syntactic answer to a type question — the last 4
  corpus errors clear.** GRDB's `collated(_:_:)` terminates by returning `self.init(impl:
  .collated(…))`, where `.collated` is an enum case; in its other branches the same
  spelling is the recursive static func. Which one a leading-dot member means is decided
  by contextual type, so Pass 1's base-case test saw `return <a call>` in every branch and
  Pass 2 believed it. Pass 1 now records the *positions* of every callee name in such
  returns and defers; Pass 2 asks the index what each name at each position is (a direct
  read of occurrence data, no line heuristics) and a cycle is bounded when some
  participant's return resolves entirely outside it. Both failure directions are
  conservative: an unrecorded or unresolvable name counts as staying in the cycle, so
  missing index data can only add findings. Measured: GRDB.swift 4 errors → **0**;
  swift-collections' single known warning unchanged.
  Design: `project/plans/proposals/TheIndexKnowsWhichBranchReturns.md`.

### Added

- **A truncated run says so (Change C).** A default run stops at its first failing checker,
  and every checker ordered after it was reported as *"not selected"* — language
  indistinguishable from a deliberately narrowed run, which is how one package's false
  positives stayed invisible for months (`ContainmentIsNotInvocation.md` §2.4). The runner
  now returns a `RunOutcome` whose `RunTruncation` names the stopping checker and every
  selected checker that never ran; the terminal summary prints them as **NOT REACHED — 0
  findings from them means nothing** with a pointer at `--continue-on-failure`; and the
  telemetry record carries `truncation` (corpus-kit 1.15.0, optional field, no schema bump)
  so dashboards can finally distinguish "ran and found nothing" from "never ran". Exit codes
  are unchanged. **Expect visible finding counts to rise** on any repository with an early
  failure — behaviour did not change, the reporting stopped implying the tail was clean.

### Performance

- **The IndexStoreDB database persists across runs; ingestion is no longer paid per run.**
  `IndexStoreSession` built the LMDB database in a UUID-named temp directory and deleted it in
  `deinit`, so every run re-ingested every unit record of the store (3,402 here) from scratch —
  profiled at the entire working set of a 15s `--check recursion` run, while the first suspect
  (`TypeDiscriminator`, added 2026-08-24) appeared in zero samples. The database now lives
  beside the store (`.build/quality-gate-indexdb-<store>`), so whatever wipes the store wipes
  the database, and an unusable directory demotes — wipe-and-retry once, then the old ephemeral
  behaviour as the ladder's floor.

  Persisting the directory alone was measured insufficient: IndexStoreDB saves its database
  (renames `v13/p<pid>-…` back to `v13/saved`) only in its destructor, and the process-lifetime
  `SharedIndexStore` cache meant no session was ever released. The CLI now drains the shared
  cache after all checkers finish (`SharedIndexStore.drain()` /
  `KeyedAsyncCache.removeAll()`, guarded against resurrecting in-flight constructions).

  `unreachable`'s `IndexStorePass` carried a private copy of the same throwaway pattern — a
  *second* full ingestion in the same gate run — and now routes through `SharedIndexStore`.

  Measured (release, `--check recursion --no-cache`): 15.1s before; 20.9s cold (first
  ingestion); **9.3s warm**, with the unit-processing thread down from 4,211 profile samples
  to 40. Design and measurements: `project/plans/proposals/IngestionIsNotAnalysis.md`.

### Changed

- **The README now leads with the documentation ladder rather than the word "linting".** The
  opening described the package as "Modular, AST-powered static analysis" — a category, not a
  capability, and the category is crowded. What is actually unusual here is that `doc-code`,
  `doc-run`, and `doc-claims` treat an article as a program: assemble it, run it twice, and
  compare the figures it publishes against what it computed. The opening now says that first,
  quotes a real `doc-run` run, and states plainly that `doc-claims` reports **0 claims across 0
  articles** on this repository because nothing here has adopted the `// Result:` convention —
  the checker's find came from another package. A headline feature the repository does not
  itself use is worth disclosing before a reader discovers it.

### Fixed

- **Six stale figures in the README, none of which anything compiled.** Every one had drifted
  in the same direction — downward, because the package grew and the prose did not:

  | Claim | Said | Actual |
  |---|---|---|
  | Checkers | 33 | 45 built-in |
  | Tests (opening) | 1,732 | 3,326 |
  | Tests (tree) | 1,662 across 151 files | 3,326 across 59 targets |
  | Checker modules | 29 | 45 |
  | DocC catalogues | 27 | 35 |
  | `doc-code` scope | 50 articles, 152 fences | 56 articles, 161 fences |

  The test figure is now the **executed** count from a full `swift test` run (3,257
  swift-testing cases + 69 XCTest, 0 failures), not a count of `func test` / `@Test`
  declarations. Those disagree — a declaration grep returns 3,505 — and the executed number is
  the one a reader can reproduce with one command.

  The checker count needed a definition, not just a recount. The gate prints **46**; the
  registry holds **45** built-ins, and the 46th is `CustomRulesChecker`, present only because
  *this* repository declares custom rules. The README documents the tool, so it claims 45 and
  the difference is now stated rather than left to look like an inconsistency.

  **This is the same failure `doc-lint`'s scope note already records**, and it is worth naming
  twice: a number written into prose has nothing checking it, so it survives exactly as long as
  nobody recounts. The durable repair is not a more careful edit — it is preferring figures the
  checker computes and prints on every run. `doc-code`'s "56 articles · 161 fences · 0 not
  analyzed" and `doc-run`'s "54 ran cleanly and reproducibly" cannot go stale, because nothing
  stores them.

### Fixed

- **A stale claim shipping inside the binary.** The hint on `self-reference-unresolved` still told
  readers that "the index pass ... does not yet [admit self-edges] — it reports cycles of two or
  more participants only". It admits them as of the previous commit, which is the entire reason
  those notes fell 292 → 34. Caught by reading the deployed binary's own output rather than the
  source. A message string is exactly as capable of outliving its fix as a design document is, and
  is read by more people; it now names what a surviving note actually means — a file the index
  could not see, and which of the three reasons applies.

- **A fresh index store can still be useless, and the pass now says so.** bitchat matched 0 of
  1900 base cases. Its store holds 140 units — every one a Clang `.pcm` module, not one Swift
  source unit — because its index build failed before reaching the package's own code, leaving an
  artifact new enough to pass the freshness check. **Freshness was checked; usefulness was not.**

  Nothing was mis-reported, because supersession is already scoped to files the index actually
  covered, so bitchat degraded to "the syntactic pass decides". What was missing was diagnosis:
  the coverage note now distinguishes *no symbols at all* from partial coverage, and reports the
  number of files indexed rather than leaving it to be inferred.

  **The residual `self-reference-unresolved` notes are mostly not a gap.** Classifying all 34
  across the survey gives three kinds, and only one is a defect: ~23 are code not compiled in
  this configuration (a `#if os(Windows)` file on macOS; swift-collections targets behind the
  `UnstableContainersPreview` package trait, which is off by default) — no index will ever cover
  those and the note is correct; ~5 are in test targets, which `swift build` does not compile;
  the rest are bitchat's. Documented in the checker's own DocC rather than left to be rediscovered.

### Fixed

- **The index pass now adjudicates direct self-recursion, and 258 of the 292 undecidable notes
  went away.** Tarjan reports direct recursion as a *one-node* component and the cycle loop
  required two or more participants, so nothing in the index pass ever looked at a self-call.
  That was tolerable while the syntactic pass reported every self-call it could name; it stopped
  being tolerable once that pass began deferring overloaded signatures to an index pass that was
  not looking.

  USR identity is the whole point: `encode(_ value: Int16)` calling `encode(value.databaseValue)`
  reaches a *different* USR, so it produces no self-edge and no finding — the question syntax
  could not answer. Across the corpus, `self-reference-unresolved` falls **292 → 34**,
  `unconditional-self-call` **14 → 10** (and those ten are now confirmed by USR rather than
  guessed), `mutual-cycle` errors **48 → 30**, corpus totals **65 errors / 14 warnings → 47 / 10**.

  The remaining 34 notes are all in files the index could not see, and the pass reports its
  coverage rather than leaving that to be inferred. Supersession is deliberately restricted to
  covered files: bitchat's index covers nothing under its package root, and dropping the
  syntactic findings there would trade every finding in the package for none.

  **Three things had to be right, and each was found by the fix failing on the corpus first:**

  - Direct recursion and a cycle need **different** base-case tests. A branch returning some
    other call bounds the first but not the second, since that call may be the next participant.
    Both are now carried separately; conflating them is what silently moved `mutual-cycle` 89 → 72
    on an earlier attempt.
  - **Computed properties and subscripts had no base-case analysis at all** — only functions
    recorded a `DeclarationInfo`. The index graph admits their accessors, so GRDB's
    `containsNonNullValue`, which ends in `return false`, read as unbounded. Both now record one.
  - **IndexStoreDB names accessors `getter:name` / `setter:name`** while the AST records the
    property as `name`. Before that prefix was stripped, the first corpus run reported 38
    findings and *every one of them* was a property getter.

### Fixed

- **`mutual-cycle` stopped trusting a text scan: GRDB 18 → 6 errors, SQLite.swift 2 → 0,
  swift-async-algorithms 2 → 0, no package worse.** The index pass decided whether a cycle was
  bounded by reading the participants' body **text** and looking for the literal `"guard "`,
  inside lines it delimited by counting braces with no awareness of strings or comments. Every
  other shape that bounds a cycle — a bare `return`, or a `return` of anything that is not a
  call — was invisible to it, so bounded cycles were reported as unbounded.

  Pass 1 already answers this correctly from the AST. It now carries that answer across, keyed on
  the definition's canonical path plus its display name: `makeFunctionDisplayName` produces
  `_subtracting(_:_:)` and so does IndexStoreDB's `symbol.name`. Keying on the *line* was tried
  first and matched barely half the corpus — a declaration's line drifts between the passes
  (attributes, multi-line signatures) and a near-miss silently drops the base case. By name the
  rate is 90–95%.

  swift-async-algorithms is the shape that proves it: `AsyncBufferedByteIterator`'s
  `reloadBufferAndNext()` ↔ `next()` really is a cycle, and really is bounded — by
  `if finished { return nil }` and a `_fastPath` early return, neither of which is a `guard`.

  **This surfaced a second, older defect and needed it fixed too.** Both base-case walkers
  returned `.skipChildren` from `visit(ReturnStmtSyntax)`, so a `guard` inside a closure within a
  *returned expression* was never reached — swift-collections' `_subtracting_slow` reaches its
  guard through two nested `read { }` closures. The AST pass had been calling those functions
  unbounded all along and the text scan happened to mask it; removing the mask made the
  disagreement visible as five new errors. With the walkers descending, swift-collections is
  unchanged at 6 rather than up at 11.

  A computed coverage note reports how many indexed definitions were marked bounded, so the
  bridge's reach cannot go stale. It reads 0 for bitchat, whose index covers nothing under the
  walked root; Pass 2 contributes no cycle findings there either way.

### Performance

- **`complexity`'s residual superlinearity was the converter defect one level up: n^1.81 → n^0.83,
  and 53.83s → 5.50s on the 259 KB fixture.** The earlier converter sweep closed with `complexity`
  at n^1.37 and recorded the honest uncertainty — *"the converter was a term and not the term …
  CallGraphAmplifier's graph work or BigOEstimator are the untested suspects."* Both suspects were
  wrong.

  A `sample` of a live run attributed 62% of `scanProject` to `CallGraphAmplifier.analyze`, and
  3417 of its 4950 samples to `SourceLocationConverter.init` under `CallFinder.init`. The earlier
  fix had moved that converter out of `recordCallIfLocal` (per call expression) and into
  `CallFinder.init` — but `CallGraphBuilder.build` constructs a `CallFinder` **per function**, so
  the cost went from O(calls × file) to O(functions × file). Still quadratic, one level up, and
  invisible to a fix that had just declared the module done. It is the same shape that same commit
  caught in `PatternDetector.findSuppressedLines` and did not look for here.

  The converter is now built once per file in `build` and passed in. Measured on a function-dense
  series, 244.68s → 10.59s at 272 KB (23×); on the original variadics fixture, 53.83s → 5.50s
  (9.8×). Findings identical on Alamofire (22), SQLite.swift (6), Sitrep (4) and swift-url-routing
  (1), with a regression test pinning that call-site line numbers stay file-absolute — a converter
  built from the wrong tree would renumber every caller after the first.

  An earlier attempt at this residual guessed `CallGraph.callees(of:)`'s linear scan, made it
  **slower** (53.83s → 73.18s), and was reverted. The profiler settled in one run what two
  hypotheses had not.

### Fixed

- **A self-named call is not a self-call: `unconditional-self-call` 279 → 14, and
  `protocol-extension-default-self` 78 → 10 across the 22-package corpus.** The rules matched
  type context + base name + argument labels, which is stronger than bare-name matching and
  still not enough, because Swift resolves overloads by *parameter type*. GRDB declares
  fourteen `encode(_:)` overloads in one file; `encode(_ value: Int16)` calling
  `encode(value.databaseValue)` targets a sibling, not itself.

  Where a signature has more than one implementation, syntax cannot choose, and the site is now
  recorded as **`recursion.self-reference-unresolved`** at note severity rather than asserted as
  recursion. The census is project-wide — a Swift type spans files, and swift-collections
  declares `_ptr(at:)` for `Bucket` in one file and for `Int` in another — and counts only
  declarations with bodies, because a protocol requirement and the extension default satisfying
  it share a signature but are one function.

  A second family came from the base-case heuristic, which accepted only `return <non-call>`.
  Two shapes it missed: a terminating branch that returns a *different* call (GRDB's
  `SQLExpression.between` ends with `self.init(…)`), and an implicit return (Ignite's
  `flatten(_:)` reaches `[]` as the value of an `if` expression, with no `return` keyword).

  **Direct self-recursion and a mutual cycle need different base-case tests**, and conflating
  them is a silent weakening: a branch returning some other call bounds the first but not the
  second, since that call may be the next participant. An intermediate version shared one test
  and moved `mutual-cycle` from 89 to 72 as a side effect. The questions are now asked
  separately and `mutual-cycle` is unchanged at 89, which is the check that the split landed.

  Corpus totals: **174 errors / 279 warnings → 106 errors / 14 warnings**, with 276 sites
  recorded as unresolved. About 5 of the 14 survivors are still false — overloads whose labels
  differ by an extra defaulted parameter, which the census cannot see and only type resolution
  can settle. Design: `project/plans/proposals/SelfCallsNeedTypeAwareness.md`.

- **The same defect in subscripts: `subscript-self` 31 → 0, `subscript-setter-self` 10 → 0.**
  `containsSelfSubscriptCall` matched every `self[…]` with no label or arity comparison at all,
  so SwiftyJSON — which declares five subscripts, with `subscript(sub:)` delegating to
  `subscript(index:)` and `subscript(key:)` — reported on all of them. Subscripts now go
  through the same project-wide census, with two corrections the shape required: subscripts do
  **not** promote a parameter name to an argument label (`subscript(index: Int)` is called
  `self[index]`, where `func f(index:)` is called `f(index:)`), and an extension of a nested
  type now shares that type's context — `extension Row.ScopesView` yielded `ScopesView` while
  `struct ScopesView` nested in `Row` yielded `Row.ScopesView`, so the two halves of GRDB's
  type never met. Of the 41 findings, 25 were resolved outright by label comparison and 16
  became notes.

  Corpus totals across both parts: **174 errors / 279 warnings → 65 errors / 14 warnings**.

  **Correction (2026-08-20):** the paragraph below said Pass 2 "has no base-case data". Precisely:
  `baseCaseUSRs` was passed empty and that path was dead, but `scanForBaseCases` supplied base
  cases by scanning body *text* for the literal `"guard "`. Cycles had weak data, not none. The
  claim held only for single-node components, which that scan skipped outright — which is why the
  single-node experiment reported 207 sites. See the 2026-08-20 entry for the replacement.

  **Recorded, not fixed:** routing these rules through the index pass was tried and reverted.
  Pass 2 skipped single-node components (`where component.count >= 2`) so it never looked at
  self-calls at all, and `RecursionAuditor` passes it `baseCaseUSRs: []` — with no base-case
  data it reported 207 corpus sites, bounded and unbounded alike. That same empty set means
  `mutual-cycle` over-reports today. Wiring per-symbol base cases into Pass 2 is the
  prerequisite for adjudicating the 276 notes.

### Fixed

- **`recursion.computed-property-self` resolves references instead of matching names: 89 corpus
  findings became 3, and all 3 are real.** Walking the AST is not automatically semantic.
  SwiftSyntax knows `return sql` is a `DeclReferenceExprSyntax` named `sql`; it cannot know
  whether that resolves to the enclosing property or to a local declared two lines earlier. The
  rule was name matching with a tree walk in front of it.

  Scope was measured before the fix was designed, and the first estimate was wrong: the proposal
  said "20 findings, all false" from reading nine repositories by hand; classifying every site
  across all 22 gave **89**, in four categories rather than two. Three distinct defects, only one
  of which was the scope stack the proposal named:

  - **Key path components** (35 sites) — the visitor fired on the `declName` inside a
    `KeyPathPropertyComponentSyntax`, so `\.retryCount` in `var retryCount` matched itself. This
    was the largest category and was absent from the design; §12's adversarial review had
    predicted exactly such a third symptom.
  - **Shadow tracking, incomplete and mis-scoped** (30 sites) — only `ValueBindingPatternSyntax`
    and `SwitchCaseSyntax` were tracked, so a plain `let sql = …` was never seen at all; and for
    `if let x` the binding sits in the *condition*, making the body a sibling node where the
    depth counter read zero throughout. Replaced by `LexicalScope`, a push/pop stack over blocks,
    closures, and case bodies, declaring names in `visitPost` so lexical *ordering* falls out of
    the traversal — a local declared after a reference does not shadow it.
  - **A same-named method** (12 sites) — `var asISO8601 { asISO8601() }` matched the callee.
    Swift permits the property/method pair only when the method is parameterized so its full name
    differs (`asISO8601(timeZone:)`), so the rule keys on the base name.

  Every other recursion rule is byte-identical across the corpus, which is the evidence the
  change stayed inside the two call sites it touched. The 3 survivors are genuine: three copies
  of one idiom in swift-nio's test utilities whose `else` branch really does contain
  `let isFulfilled = self.isFulfilled`. Design:
  `project/plans/proposals/RecursionNeedsScopeTracking.md`.

  **Also a false negative, fixed in passing.** The old walker skipped *every* child of a member
  access to avoid matching the member name, and skipped the base with it — so
  `var name: String { name.uppercased() }`, unconditional infinite recursion, was never reported.

  Subscript overload matching (`subscript-self`, 31 corpus sites) is untouched and remains open.

### Changed

- **`security.command-injection` now detects injection, and is re-enabled.** It was worded for
  injection — "validate and sanitize dynamic arguments", CWE-78 — and its mechanism was
  `callee == "Process"`: it flagged every construction and never inspected an argument. It had
  been disabled in `.quality-gate.yml` on reasoning that was sound for the name and wrong for
  the mechanism, and that also removed the only signal pointing at every direct spawn in the
  tree — nine were unbounded, and one cost 46 minutes to a hang.

  The split that comment asked for is now complete. Containment shipped earlier as
  `bounded-io.process-construction`; this is the injection half. The rule fires only when a
  **shell** is invoked with a `-c`-family flag **and** the command string is not a literal. All
  three conditions are required because each alone is a false positive: shells legitimately run
  literal scripts, `-c` is also `git -c user.name=…` and `swift build -c release` — both present
  here and both pinned by tests — and interpolating into an `argv` element is ordinary, since a
  `Process` given an arguments array invokes no interpreter at all. Flagging that last case is
  the noise that gets a security rule switched off in the first place.

  Deliberately no taint tracking: whether an interpolated value is attacker-controlled is not
  decidable in one file, and a single-file visitor that pretends otherwise reports confident
  nonsense. Interpolating any value into a shell command is the finding; a safe one is
  acknowledged with `// SECURITY:`, not silently permitted. Zero findings in this repository,
  which runs no shell. Design: `project/plans/proposals/CommandInjectionEarnsItsName.md`.

  Three existing tests encoded the replaced behaviour and were rewritten rather than deleted:
  two asserted that a bare `Process()` is an injection finding (now pinning that it is *not*,
  so the conflation cannot return), and one hardcoded "10 stale rules" against a date that only
  worked while every rule shared one review date — reviewing a single rule broke a test that was
  never about the number 10. It now derives both the horizon and the expectation.

### Added

- **`boundedIO.kernelPath` — a repository names its own bounded-subprocess kernel.** `bounded-io`
  permitted the unbounded primitives in exactly one hardcoded path,
  `Sources/QualityGateCore/ProcessRunner.swift`, which names *this* package's own type. A foreign
  repository has no `QualityGateCore`, so every one of its spawn sites was outside the kernel by
  construction, the emitted fix named a symbol it could not import, and — the part that made the
  rule unusable — **writing the correct fix did not clear it**: a project that built a real
  bounded kernel at its own path got that kernel flagged like any other file. The only reachable
  green state was an `// Unbounded:` marker on the kernel's own `Process()`, which inverts what
  that marker means.

  Found by running `bounded-io` against CoverLetterWriter, where it reported 8 errors across 3
  files. Six were real and are worth recording as the argument for keeping the rule strict once
  it is configurable: a helper wrote its entire stdin payload before reading a byte of stdout
  (1 MB through `/bin/cat` deadlocks permanently — reproduced, `SIGKILL`ed at 25s, 11ms after the
  fix), and neither helper had any timeout, one of them shelling out to a CLI LLM.

  The default preserves today's constant, so this repository's verdicts are byte-identical and a
  test pins that. Declaring no kernel remains a finding rather than an exemption — a repository
  with nine unbounded spawns and no kernel is the one that most needs telling. One path, not a
  list: the trust argument rests on the kernel being small enough to read in one sitting.

### Fixed

- **Ten more checkers audit the repository rather than a hardcoded `Sources/`.** `safety` was
  not alone: `concurrency`, `recursion`, `pointer-escape`, `fp-safety`, `memory-lifecycle`,
  `accessibility`, `hig-auditor`, `mcp-readiness`, `context` and `complexity` each appended the
  literal `Sources` to the resolved root, by copy-paste. Every one now walks the root through
  `SourceWalker` and states its coverage. Several carried a second defect behind the first:
  `concurrency`, `recursion`, `pointer-escape`, `fp-safety` and `memory-lifecycle` never
  consulted `excludePatterns` at all, so paths the configuration excluded were audited anyway.

  Three findings the mechanical description would have missed:

  - **Four checkers computed status as `allDiagnostics.isEmpty`**, so adding a coverage note
    would have turned every run red. They now test for a non-note diagnostic — the same trap
    that once silently downgraded six real `process-safety` findings when its coverage note
    was added.
  - **`mcp-readiness` was double-counting.** It walked `Sources/` *and* each
    `mcpReadiness.additionalPaths` entry, and those resolve under the project root, so a file
    covered by both was audited twice and counted twice in `mcpFileCount`. One root walk ends
    it; `additionalPaths` is subsumed rather than ignored, and still loads.
  - **`complexity` derived module names from the `Sources/`-relative path**, so the first path
    component *was* the module. Widening moved the module one component along, and without the
    corresponding fix every record in the corpus would have reported its module as `"Sources"`.

  `memory-lifecycle`'s `Tests/` skip, `context`'s `isTestFile` skip and `fp-safety`'s
  `skipTestFiles` flag all survive the widening, now stated as judgements rather than left to
  look like the defect. `fp-safety`'s is the clearest: it skips test code because
  `test-quality` covers it as `exact-double-equality` — same detector, different reach.

  `legibility` was **not** widened. It already walked the root and filtered `/Sources/`, and
  that filter measures the *public API surface* and whether the modules publishing it carry an
  orientation doc. A test target's `public` symbols are not API anyone imports, so widening it
  would report every test module as undocumented and make the metric mean less. The filter is
  now documented as deliberate, because an unexplained filter is indistinguishable from the
  bug and the next reader would have "fixed" it.

### Changed

- **`complexity` telemetry covers a larger file set from this commit on.** Its records now
  include `Tests/`, `Plugins/` and the package manifest, where before they covered library
  code alone, and module names resolve past the container directory so `Tests/FooTests/X.swift`
  reports `FooTests` rather than `Tests`. Any trend line crossing this commit **steps rather
  than drifts, and the step is a scope change, not a regression** — recorded here because a
  metric that moves for a reason nobody wrote down is indistinguishable from one that moved
  because the code got worse, and this project's own pulse would have read it that way.

- **`safety` audits the whole repository, not a hardcoded `Sources/`.** The checker
  appended the literal `Sources` to the resolved project root, so a force unwrap in
  `Plugins/`, in `Tests/`, or at the package root passed a gate that forbids force
  unwraps unconditionally. This is the same narrow-scope defect that let six deadlocks
  sit under `process-safety` for months, and the fix is the same one: the walk comes from
  `SourceWalker`, which is what makes pointing at the root safe — it already refuses
  build output, Xcode containers and git-ignored trees. The private enumerator that used
  to live in `auditDirectory` is gone with it; it honoured `excludePatterns` but not the
  git-ignore rule, the default skip list, or `.xcodeproj` containers, so the checker had
  two different answers to "which files are ours" depending on which code path asked.

  The widened walk found **74 real findings** in this repository — 42 force unwraps, 12
  C-printf format calls and 20 newline-literal splits, including one in the SwiftPM
  plugin where a CRLF build log would make `suffix(20)` print the entire log instead of
  its last 20 lines. All are fixed in this commit, none suppressed. `safety` now also
  emits a `safety.coverage` note stating how many files it read, because a checker that
  examined nothing must not print what a checker that found nothing prints.

- **`SourceWalker` no longer descends into a nested package.** A directory carrying its
  own `Package.swift` is a *different* package — its own manifest, targets and rules,
  neither built nor released by the one being audited — so reporting this project's house
  rules against it is the same incoherence the git-ignore rule exists to prevent,
  arriving by a route `.gitignore` cannot describe: a checked-in prototype is tracked,
  not ignored. It generalises without a list to maintain, and the count is reported in
  `WalkResult.exclusionClause` alongside the other exclusions rather than being silent.
  Two such packages exist here: the `docref` prototype kept as the evidence behind a
  written proposal, and the cross-module test fixture. The root's own manifest cannot
  skip the root — the enumerator never yields the root itself, and a test pins it.

- **A timed-out child's descendants now die with it.** The deadline (shipped `1e9f643`)
  bounded the gate's *wait* but leaked the process *tree*: `Process.terminate()` on a
  child that had already exited is a no-op, so a grandchild holding the pipe survived —
  observed in the wild as a `swift-test` orphan alive after 6h55m. `Process` already
  spawns every child as leader of a fresh process group, and a group outlives its
  leader, so the fix is deadline-side only: `kill(-child, SIGTERM)`, the existing grace,
  then `kill(-child, SIGKILL)` as the guarantee. Two probes first *refuted* the planned
  fixes — the naive red test passed (Foundation already group-signals a live child), and
  the proposed `posix_spawn` rewrite would have re-created what Foundation provides. The
  handoff's swift-subprocess migration is therefore **not needed for this bug** — its
  teardown is also just a group signal — and the wrong plan is kept, struck through, in
  `project/plans/proposals/SubprocessDescendantReaping.md`. A descendant that re-groups
  itself (`setsid`) still escapes; that limitation is shared by every mechanism
  considered and is recorded as out of scope.

### Performance

- **A warm gate run is 2.1 seconds.** Down from 15.9s measured the same day on the same
  scope (`--check all --exclude test --exclude disk-clean`), via three independent fixes,
  each measured separately (`project/plans/proposals/SharedFileDigestMap.md`):

  1. **The file-digest map is shared across checkers** (−7.4s). ~41 cache-participating
     checkers each hashed the same ~660 files to compute their fingerprints — roughly
     27,000 SHA-256 reads per warm run whose results were identical across checkers. A
     per-run `FileDigestCache` (path → digest, `Mutex`-backed, hashing outside the lock)
     collapses that to one hash per file. Fingerprints are byte-identical with and without
     it; the cache changes cost, never the key.

  2. **`doc-generated` no longer misses on every run** (defect, not tuning). Its salt
     encoded the config slice with a plain `JSONEncoder` — no `.sortedKeys` — and
     `JSONEncoder` buffers keyed containers in a `Dictionary`, so key order follows
     per-process seeded hashing and the same configuration encoded to different bytes in
     every process. The fix is `CheckerFingerprint.canonicalSalt`, which the two
     previously-correct copies (`SourceCacheInputs`, `DocCodeAuditor`) now share too.

  3. **The telemetry sidecars stopped re-scanning the tree on cache-hit runs** (−5.8s).
     `TelemetryEmission` ran `ComplexityAnalyzer.scanProject` (~1.5s) and
     `LegibilityAnalyzer.orientationReport` (~4.3s) after *every* run, serially, even when
     the corresponding checkers were cache hits — the cost was outside `check()`, so no
     result cache could see it. Both artifacts are now cached in `ResultCache` under the
     same fingerprint contract (`loadArtifact`/`storeArtifact`), keyed by the owning
     checker's own declared input set; the orientation report is re-stamped with the
     current run's timestamp on a hit because the analysis is a pure function of its
     inputs and the stamp is not.

  A fourth change — memoizing the per-checker source walks in `SourceCacheInputs` —
  measured **zero improvement** and is kept only because it is small, tested, and makes
  the walk's snapshot-per-run semantics explicit rather than incidental. Recorded here so
  nobody re-proposes it as a speedup.

### Added

- **`--profile code` — run the checkers that judge code, and nothing else.** Built to make
  surveying unfamiliar Swift repositories one command rather than eleven hand-assembled
  exclusions.

  The exclusions were not merely tedious. Forgetting `--exclude consistency` scores a
  stranger's repository against *our* institutional pulse, and forgetting `--exclude status`
  measures it against our Master Plan — both produce findings rather than errors, so nothing
  announces the mistake.

  **`--profile` implies `--foreign`.** A profile run analyses read-only and redirects every
  write to the overlay; `--resident` alongside it is refused as contradictory rather than
  resolved by precedence, because whichever way precedence fell it would be silent. Selection
  and write-behaviour are different axes and coupling them is deliberate: the failure mode of
  forgetting `--foreign` is writing into someone else's checkout.

  `--check` and `--exclude` compose on top, so `--profile code --check legibility` runs the
  code profile plus legibility — the classification decides the default, not what is reachable.

  Measured against `kylehughes/Coalesced`: 26 of 43 checkers, same 8 errors as the hand-built
  command, one fewer warning (the "No CHANGELOG" finding, correctly dropped as a convention
  judgment about someone else's repository), and nothing written anywhere.

### Changed

- **A checker is now a pure function of (root, configuration).** `Configuration` gains
  `projectRoot` — runtime state set by the CLI from `RunEnvironment`, deliberately
  excluded from `CodingKeys` so it never reaches a `.quality-gate.yml` or perturbs a
  cache salt — and `resolvedProjectRoot`, whose lazy cwd fallback preserves exact prior
  behavior for every caller that never sets it. ~96 reads of
  `FileManager.default.currentDirectoryPath` across 55 files now flow through the
  configuration; the eight that remain each mean "where the user invoked this" and are
  enumerated with reasons in `project/plans/proposals/CheckerRootThreading.md`.

  The same pass closed the spawn half: `swift build`, `swift test`, `xcodebuild`, and
  plugin subprocesses now run with `currentDirectory:` set to the resolved root instead
  of inheriting the process cwd — previously the existence check and the subprocess
  could silently examine different trees whenever the root diverged from cwd. Toolchain
  probes and spawns that pass their target explicitly (`--package-path`) are exempt by
  classification, not omission. Both halves are pinned end-to-end:
  `ProjectRootEndToEndTests` (read) and `BuildCheckerRootTests` (spawn) drive checkers
  at a fixture root while the process cwd is the gate's own checkout.

- **`QualityChecker` gains `kind` and `effect`, with no default implementations.** ⚠️
  Source-breaking for external conformers, exactly as `summary` and `category` were in 3.0.0.
  Released as a minor version because the external conformer set is empty — recorded here so a
  future reader does not mistake it for an oversight.

  A default would defeat the point. The runner holds checkers as `any QualityChecker`, so a
  witness supplied only by an extension dispatches statically and would classify every checker
  whose author never considered the question — silently, and plausibly.

  ``CheckerKind`` answers whose standard is being applied: `code`, `documentation`,
  `convention`, `institutional`. It is deliberately not ``CheckerCategory``, which groups the
  README for readability and does not carve at this joint — `consistency` and `status` are
  `specialty` there, and `institutional` here.

  ``CheckerEffect`` answers what a checker leaves behind: `readOnly`, `writesOutsideTree`,
  `writesTree`. Three cases rather than a Bool because the distinction is real and was got
  wrong once: `memory-builder` was assumed to have written into a surveyed clone and had in
  fact written to `~/.claude/projects/…`. Compilation output is explicitly *not* a write —
  treating `.build/` as mutation would make the property vacuous.

  Profiles derive from both. Membership cannot drift from the registry, because there is no
  second list to keep in sync: a new checker does not compile until it is classified.

- **`logging`, `idiom`, `legibility`, `swift-version`, `hig-auditor` and `context` are
  `convention`, not `code`.** They judge how code *reads*, or apply a standard someone else
  did not sign up to — `os.Logger` over `print` is a house rule, HIG conformance is Apple's
  taste, and `context`'s consent-and-surveillance findings are a judgment about a stranger's
  product decisions rather than a defect report. All remain reachable with `--check`.

  `test-quality` stays `code`, deliberately. The case against it was its false positives, and
  all eight in the Coalesced run came from `missing-assertion` — a rule with its own proposal
  to fix. Excluding the checker would treat the symptom and hide the evidence that produced the
  fix; the checkers most worth surveying are the ones we trust least.

### Fixed

- **`consistency` no longer counts notes as violations.** ⚠️ **This changes every project's
  score.**

  Checker-level failure was being used as a proxy for diagnostic-level violation: when a
  checker failed, every diagnostic it emitted was counted against its rule, notes included.
  `doc-code.coverage` — severity `note` in all 12,844 recorded occurrences, and emitted
  precisely when the checker *succeeds* — accumulated a violation cluster of 1,903 that no
  repository could drive to zero, because emitting it is the success path.

  Counting now filters on `Diagnostic.isViolation` (`severity >= .warning`), which ships in
  `quality-gate-types` 1.4.0 so the gate and the Institutional Judgment System cannot disagree
  about what a violation is. Applied at three sites:
  `PolicyDiscoveryAuditor.extractFailedRuleIds`, `.buildCheckerLookup`, and
  `PulseRefiner.detectClusters`.

  Severity decides, never the rule's name. `doc-generated.region-missing-line` reads
  note-shaped and is `error` in all 639 recorded occurrences; its cluster is unchanged. Expect
  pure-note clusters (`doc-code.coverage` at 1,903, `doc-comment-code.coverage` at 9,408) to
  vanish and error-backed ones (`exact-double-equality` at 2,149) not to move.

  **Existing corpus clusters remain wrong until a pulse regenerates** — that is a corpus
  operation, not a code one, and is deliberately not done here. Whether historical pulses get
  rewritten or annotated is still open: rewriting erases the record of the bug, annotating
  keeps a pulse whose numbers no longer reproduce.

- **`gpu-safety` rule 3 no longer fires on files with no Metal in them.**

  `waitUntilCompleted()` is not a Metal spelling. `MCP.Server`, `Process`-style wrappers and
  hand-written actors all name their blocking shutdown wait exactly that, and rule 3 matched the
  bare method name — so it reported a server's run loop as silent GPU memory corruption in a
  package with no Metal anywhere in it. An error a reader cannot act on, in a rule whose entire
  value is that its errors are real.

  The rule is now gated on `hasMetalContext(_:)`, computed once per file. A file that never
  names Metal cannot hold an `MTLCommandBuffer`, so `import Metal` / `MetalKit` /
  `MetalPerformanceShaders` and any `MTL` type are a sound gate. `commandBuffer` and
  `CommandBuffer` are admitted alongside them because the buffer is often reached through a
  helper that carries the import rather than the file that uses it — without those, this false
  positive would have been traded for a false *negative* on real dispatch code, which is the
  worse trade for a rule that emits errors.

  Two limitations, stated because the fix is a heuristic rather than type resolution. It is a
  raw substring scan, not a syntactic one, so `MTL` inside a comment or string literal turns the
  rule back on — the right direction for a safety rule, but the false positive is reachable
  again in a file that merely mentions Metal. And it is file-scoped: a large file with genuine
  Metal code elsewhere plus an unrelated `waitUntilCompleted()` still fires. Both need the
  receiver's type, which this auditor does not resolve.

  Of the two new tests, only `silentWithoutMetalContext` is red before the change — that one is
  the bug. `firesOnMetalImportWithOpaqueReceiver` passed already; it is a ratchet against
  someone later "tightening" the gate into receiver-name matching, which would miss every buffer
  not literally named `commandBuffer`. The existing six needed no edits: their fixtures already
  say `commandBuffer` or `MTLSize`, so they keep their context.

- **The auditor's own findings are no longer counted as violations.**

  A `consistency-finding.*` diagnostic reports *on* violations; it is not a violation of
  anything in the code — the coverage-note category error one level up, made about the auditor
  rather than about a checker.

  It was structurally invisible until the change below: `consistency` reports `passed` or
  `warning` and **never** `failed`, so the old status filter dropped it every time. Counting
  warnings from passing checkers swept it in, and a pulse regeneration surfaced it —
  `consistency-finding.clusterMatch` at **322 occurrences**.

  It never self-corrects. In a normal run the audit happens before its own result is appended,
  so it cannot see itself and produces no finding — but the telemetry written afterwards
  carries the warning, so every run feeds the cluster and nothing drives it down. In the
  isolation path (`--check consistency`), which audits persisted telemetry rather than the
  current run, the loop closes properly: it matches its own earlier finding.

  Excluded at both counting sites. A companion test pins `docc` still clustering, so excluding
  the auditor cannot drift into excluding passing checkers and undo the change below.

- **A violation counts wherever it was reported.** ⚠️ **This moves scores in the opposite
  direction from the note fix above — it widens what counts.**

  Counting required `status == .failed` **and** `isViolation`. Those are two different tests,
  and the status one was wrong: a checker can pass while emitting warnings — `doc-lint` does —
  and the filter dropped those warnings along with the whole checker. Score impact therefore
  depended on whether a checker chose to *fail* or merely *warn*, a decision each checker makes
  for its own reasons and unrelated to how serious the finding is. A rule could be violated
  every run for weeks and never score.

  Severity is now the only test, at both sites. `extractFailedRuleIds` is renamed
  `extractViolatedRuleIds`, because failure is no longer what it asks.

  Checker-level attribution still asks about failure: anomaly matching is about *checkers*, and
  a checker that passed did not fail whatever it reported on the way. That filter stays.

  Resolved 2026-08-15 — §15's first open question in
  `ConsistencySeverityAndProvenance.md`, deliberately decided separately from the note fix so
  the two opposite-direction score movements are attributable.

  **Regenerate the pulse after deploying this.** Cluster construction now counts warnings in
  passing checkers, so existing clusters understate.

- **`consistency` now audits the run it is printed inside of.**

  It read the newest telemetry on disk, and the current run's telemetry is written *after*
  every checker completes — so "newest" was always the run before. A clean run reported the
  previous run's findings, which meant a project on a zero-warning policy could not reach zero
  on the run after any failure. The only workaround was to run the gate twice and believe the
  second answer.

  Reproduced here on 2026-08-15 across three consecutive runs: run 1 failed `doc-generated` and
  `test-quality`; run 2 was clean but warned `missing-assertion` ×49 and `doc-generated.coverage`
  ×21 — one cluster per checker that had failed the run before; run 3, on an identical tree, was
  clean.

  `consistency` is no longer a checker in the sweep. It runs as a post-run stage over the run's
  in-memory results, after the sweep and before telemetry emission — an ordering that matters,
  since emission reads the consistency result to embed the score. `--check consistency` still
  selects it.

  In isolation there is no current run to audit, so it falls back to the newest persisted
  record and **names** it (`Auditing previous run <timestamp> — no current run in scope`)
  rather than auditing an empty result set and reporting a vacuous 1.00. Every result now
  states which run it describes.

  Architectural consequence, recorded in `project/master_plan.md`: **a checker that audits a
  run must run after it.** `QualityChecker.check(configuration:)` stays results-free; a checker
  needing the run's results becomes a post-run stage rather than reaching for persisted state.

### Changed

- `quality-gate-types` requirement moves to `from: "1.4.0"`.

## [3.0.0] — 2026-08-12

**The project's claims about itself are now checked.** Documentation must compile, run, and match
the figures it publishes. Derived prose — module rosters, the error registry, changelog links, the
checker reference — must match the tree or the gate fails. A suppression must say why. A released
version must be resolvable by whoever reads about it. None of that was true in 2.x, and none of it
required a new claim to become true: every rule below was measured against this repository, and
most of them found something on their first run.

### Breaking

- **`QualityChecker` gains `summary` and `category`, with no default implementations.** An
  external conformer will not compile until it adds both. This is deliberate: an extension-only
  default dispatches statically through `any QualityChecker` and would hand an empty description
  to every checker that forgot one, disarming the requirement exactly where it matters. The
  README's description column — the column a reader actually uses — existed nowhere in source,
  which is how four checkers shipped without a row and seven had by the time it was fixed. The
  sentence now lives beside the `id` it describes, so forgetting it is a compile error rather
  than a documentation error. 61 sites were updated, including examples inside doc comments,
  which this package's own `doc-comment-code` refused to let pass until they matched.

### Added

- **`doc-generated` (new checker) — derived content committed as prose must still match what it
  was derived from.** Ten regions across three files: six checker-reference tables in `README.md`,
  the module list and status roster in `master_plan.md` (membership derived from `Package.swift`;
  tick-boxes remain `status`'s and no generator ever flips one), the error registry derived from
  `QualityGateError`'s cases and their `///` abstracts, and `CHANGELOG.md`'s link definitions.
  `--fix` regenerates a stale region, changing only the bytes between the delimiters — it locates
  the body as a character range rather than splitting and rejoining the file, which would rewrite
  every line ending in a CRLF document while repairing three rows. On arrival it reported 65
  findings against this repository, including seven modules absent from the architecture table, a
  registry that had never listed `writeGuardViolation`, and four changelog link definitions that
  had never been written at all.
- **`quality-gate release` — the release-scoped observer.** The housekeeping obligations are
  release-scoped and every enforcement mechanism was commit-scoped, so nothing ran at the moment
  they came due. It checks that the places stating a version agree, that `[Unreleased]` has been
  emptied, and that the plan was reconciled — the temporal question, which is illegitimate at
  commit time and legitimate here because a release *is* the calendar event. Its first run found
  a master plan last updated 2026-06-04, before 2.0.2 shipped.
- **The release-tag invariant, split into the three questions it was conflating.** Parity (is the
  documented version tagged), identity (does that tag contain the entry it claims), reachability
  (is the tag actually going to the remote). Parity is advisory at commit time — the old rule
  could only be satisfied by inverting the project's own gate-then-commit order — and blocking at
  a push boundary. **No repository needs to change a hook:** git already hands `pre-push` its ref
  list on stdin and the installed template already passes it through, so the check arrives with a
  binary upgrade rather than a rollout. It found `v2.0.1` and `v2.0.2` present locally and absent
  from the remote, with the CHANGELOG advertising 2.0.2 as current.
- **`stochastic.exempt-no-justification`** — `// stochastic:exempt` must state why. A bare marker
  still suppresses, so no passing gate starts failing, but it is reported. Two defects had hidden
  behind bare markers in one release, each costing a misdiagnosis: a configured `seed` rendered
  inert on the GPU path, and a robust optimiser redrawing 92 of 100 scenarios per call, so two
  runs of the same optimisation solved different problems.
- **`memory-index` region for `MemoryBuilder`.** The index used a per-line marker, so a generated
  line that lost its tag became immortal — nothing could tell it from a hand-written one. The live
  index carried five duplicated pairs, one saying 72 targets and another 116, both loaded at every
  session start. A region expresses deletion; a line suffix cannot.

### Fixed

- **`a11y.swiftui.standard-shortcut-override` no longer flags the canonical form it asks for.** A
  reserved key bound inside the standard `CommandGroup` placement that owns it is the system
  behaviour, not a repurposing — and the rule's literal suggested fix was a functional regression,
  since `CommandGroup(replacing:)` does not confer its placement's shortcut on a custom `Button`.
- **`a11y.swiftui.tap-gesture-missing-button-trait` accepts `.accessibilityAction`** and no longer
  flags multi-tap gestures. On a container, `.isButton` makes VoiceOver announce a whole scrollable
  map as one button, which is worse than the state being reported.
- **`doc-code` finds C modulemaps under `Source/` and `src/`.** `Sources` was hardcoded, so a real
  dependency using the singular spelling was invisible and every fence importing it stopped at a
  barrier — 15 errors behind 7 barriers in one project, with the diagnostic correctly saying the
  count meant nothing while the cause was a directory that was never looked in.
- **`doc-lint` no longer reports a dependency's build-graph noise as a project warning.** A
  location-less diagnostic whose every absolute path lies under `.build/` is demoted to a note.
  `build` had always dropped these lines; the two checkers now disagree by decision rather than by
  accident of two regexes.
- **`doc-lint` examined 1 target out of 116 and reported the result as the project's
  documentation verdict.** It asked DocC about the first target of the first `.library` product —
  or, here, whatever `docTarget` named — and the other 115 were never handed to DocC at all. That
  is not degraded coverage, it is absent coverage reported as a pass. It now enumerates every
  target owning a `.docc` catalogue and passes each in one invocation (`--target` is repeatable),
  going from 1 to 31 on this package and exposing 19 real defects: 15 cross-module symbol
  references that DocC cannot resolve, three nested code spans it was reading as symbol links,
  and a parameter documented by its external label instead of its internal name. All fixed.
- **`doc-lint` now asserts its own coverage.** Examining zero targets is an error, and every run
  reports what it looked at. A checker that examined nothing and a checker that found nothing
  wrong must not print the same thing — `doc-generated` had this property from the start and
  `doc-code` was written without it.
- **DocC diagnostics were reported against the wrong file and line.** Swift 6.4's DocC puts the
  message and its location on separate lines (`--> ../Path.swift:103:54-103:54`), matching neither
  supported pattern, so every location was dropped — measured on one run, *zero* diagnostics used
  the inline format. The recovery then paired diagnostics to candidate signatures **positionally**,
  the i-th warning taking the i-th signature found, from two orderings nothing aligns. With one
  matching parameter in a package it landed by luck; with eight, every guess missed and sent three
  investigations to files whose documentation was correct. The continuation format is now parsed,
  and ambiguity yields *no* location rather than a confident wrong one.
- **`Sources/` was hardcoded in three places that scan the project under test.** A package laid
  out with `Source/` or `src/` would have had zero articles discovered and passed green. Now one
  `SourceLayout` type is consulted everywhere, matching the dependency-side fix.

- **A region matching its generator's output in the wrong order reported nothing while failing.**
  `missing` and `unexpected` are multiset comparisons, so a permutation emptied both while the
  bodies differed — a byte-mismatched region with a green verdict. Found by `checker-table`, the
  first generator whose natural order differs from one a person arranged.


### Earlier in this release

Entries written as the work landed, before 3.0.0 had a heading to sit under. They are the same
release and are kept in the order they were recorded.

- **New checker `doc-comment-code`: the examples in `///` must compile too.** `doc-code` compiles the `.docc` catalogue; this compiles the doc comments the catalogue was copied *from*. The distinction is not theoretical. Commit `65471d7` repaired 26 articles in this package and found real API drift doing it — `Configuration.default` gone, `limitToFiles` retyped, `{ … }` placeholders that never parsed — and it touched **no doc comment**. `ImplementingCheckers.md` now shows a `MyChecker` that declares its helper, imports `QualityGateCore` and returns a real `CheckResult`, *because `doc-code` forced it to*; the `///` on `QualityChecker` itself still carries the abbreviated version, and Quick Help still serves it. **`doc-code` repaired the copy and could not see the original.** Against this repository the new checker finds **43 doc fences in 26 files — 20 Swift, 23 not (18 yaml, 2 json, 1 bash, 2 untagged), 0 exempt — of which 16 fail, with five root causes.** Ten of the sixteen are one `## Usage` template copied into ten auditors, and the obvious repair fails too: the block never says `import QualityGateCore`, so a reader who copies it out of Quick Help cannot build it. Four decisions are load-bearing. **(1) The compilation unit is one fence**, not the doc comment and not the file — `HIGAuditor.swift` carries one `///` run holding two unrelated fences, a usage example and a fragment of the *reader's* SwiftUI code, so concatenating them would import `doc-code`'s collision rule into a place where its premise is false. Nobody pastes a Quick Help panel. No collision detection runs. **(2) The preamble is `Foundation` plus the owning module and nothing widens it** — not the dependency closure, not `docCode.extraImports`. Injecting `QualityGateCore` would have turned ten failures into ten passes while the examples stayed uncopyable, and it could not have fixed the four `QualityGateTestKit` fences at any depth, because `SafetyAuditor` is not in that target's closure and must not be. A preamble generous enough to make the corpus green certifies documentation the reader cannot use. **(3) Extraction is SwiftSyntax trivia, never a line regex.** A regex reports 21 Swift doc fences here; the strict count is 20, and the difference is an inline code span in `ArticleAssembler.swift:66` — in the sentence explaining why the illustrative marker is an HTML comment. A regex extractor would report the rest of that doc comment as broken, in the file that documents the rule. **(4) Untagged and foreign-tagged fences are never guessed at**, and are counted in the coverage line, because a gate that under-reports its own coverage is indistinguishable from one that passes. `<!-- docs:illustrative -->` carries over unchanged, `/// `-prefixed — verified this session by rendering a doc comment containing it through `swift package generate-documentation`: the marker leaves no trace in the rendered page, the prose either side and the syntax-highlighted code listing all survive, and the raw string appears only in the symbol graph, which is source rather than output. Shipped **opt-in** (`--check doc-comment-code`; `--full` does not enable it), **error** severity with no knob that downgrades it, `isParallelSafe = true`, `.hermetic`, no `--fix` and specifically never an auto-inserted exemption. It lives in `Sources/DocCodeAuditor` — no 117th SPM target, since `Toolchain`, `ManifestLanguageMode`, `headerSearchPaths`, `generatedModuleMaps` and `ArticleAuditor.reduce` are all reused — but takes **its own checker id**, because a shared one would turn the freshly-green `doc-code` red on the day this landed, and a gate that is red on arrival gets skipped. The documentation itself is deliberately *not* repaired here: the rule and its remediation are separate commits so the 16 findings are visible before they are answered.

- **`doc-code` reported PASSED for a catalogue in which it had typechecked nothing.** Every module in this package transitively depends on SwiftSyntax, so the assembled article's `import <Module>` failed with `<unknown>:0: error: missing required module '_SwiftSyntaxCShims'` and the compiler stopped before typechecking. Two bugs then made that invisible. **(1) The barrier test was a single string prefix.** It matched `no such module` only; the compiler has at least four ways to say it could not proceed, and the one this package produces was not it. **(2) An error with no article location was discarded.** `<unknown>:0:` has two colon-fields, `lineNumber(inHead:)` returned `nil`, and the parse loop `continue`d. Together they yielded `(errors: [], barrier: nil)` — a verdict indistinguishable from a clean article — while the coverage note still claimed "13 fences checked". This is precisely the failure `barrier` was introduced to prevent; the mechanism was right and the trigger was too narrow. **The fix is structural, not another list of phrasings**: an error the compiler could not attach to a line of the assembled program is, by construction, not a statement about a line of the article, so it is now recorded as a barrier and can never be silent. A list would need extending every time the compiler learns a new wording, and the cost of a missing entry is silence. The located `no such module` check is kept, because that diagnostic *does* name the import line and would otherwise send a reader to fix a line whose real problem is the build. The reduction moved out of `typecheck` into a pure `reduce(output:)` so it is testable without a toolchain — which is how the defect was isolated in the first place.
- **`doc-code` now resolves the C modulemaps its imports need.** `DocCodeAuditOptions.headerSearchPaths` was declared, threaded into `swiftc` as `-Xcc -I<path>`, and populated by nobody: the seam was built and never connected. It is now derived by walking `.build/checkouts/<package>/Sources/<target>/` for `module.modulemap`, in **both** shapes SwiftPM uses — under `include/` for a C target with a hand-written map (the swift-syntax shims), and beside the sources for a system-library target (`CSQLite`, which requiring `include/` missed). Modulemaps SwiftPM *generates* need a different flag, since they name their umbrella header by absolute path and live nowhere near it, so `moduleMapFiles` was added for `-Xcc -fmodule-map-file=`, collected from both the Swift Build layout (`.build/out/Intermediates.noindex/GeneratedModuleMaps/`) and the classic llbuild one (`.build/debug/<Target>.build/module.modulemap`) — which layout is on disk is a property of the SwiftPM version, not of the project. **Deliberately not read from the build manifest**, which is where these flags authoritatively live: under the Swift Build engine `.build/debug` is a symlink to `.build/out/Products/Debug`, there is no `.build/debug.yaml`, and the only llbuild manifest left is under `.build/index-build/` — an artifact of whether an index build happened to run. `docCode.headerSearchPaths` is additive for vendored C dependencies; it cannot narrow the search, because a knob that turns a red gate green is a suppression by another name.
- **`doc-code` passes the manifest's tools-version as `-package-description-version`.** `PackageDescription`'s API is gated on the `_PackageDescription` availability domain, which is empty unless that flag sets it, so every documented `Package.swift` excerpt failed with `'package(url:branch:)' is unavailable` — a fact about how the manifest API is versioned, not a defect in the documentation. `Toolchain.flags()` also offers `lib/swift/pm/ManifestAPI`, since `PackageDescription` ships beside the toolchain and is on no target's module search path. Both exist for the reason the swift-testing framework and plugin paths already do: without them the natural response is to mark the block illustrative, and the gate manufactures its own exemption for a construct it simply could not compile.
- **The documentation the fixed checker exposed.** Turning the barrier on surfaced 80 findings from parse and collision analysis alone, then 14 genuine typecheck errors behind them, across 26 articles. Repaired rather than exempted: duplicate file-scope bindings renamed from their enclosing heading; `{ ... }` and `{ … }` placeholders — which parse as separated unary operators, not as bodies — given real bodies; undefined references defined once in the earliest block that needs them. Real API drift found and fixed along the way: `Configuration.default` does not exist (it is `Configuration()`), `ConformanceQuery` takes `in session:` rather than `in: session.db`, `limitToFiles` takes `Set<String>` rather than `[String]`, `CLLocationManager.authorizationStatus()` is deprecated and `.authorizedWhenInUse` does not exist on macOS, and one force-unwrap. **The catalogue now carries zero `<!-- docs:illustrative -->` markers**: every fence in every article is a program that compiles.
- **New rule `stochastic-unseeded-test-call` — a test that calls a seedable API without passing the seed** (warning): the defect that motivated it took the mean of 100 draws from Uniform(1000, 2000) and required it in [1400, 1600] — a 3.5-standard-error bound, failing by chance roughly one run in 2,000, which is rare enough to look stable and frequent enough to bite CI. No existing rule could see it, and not because tests were skipped: the call site is `MonteCarloSimulation(iterations: 100)` and every random number is drawn *inside* the callee. There is no randomness on the line to match. What is wrong with the line is an argument that was never written. **Two passes, no type information.** Over `Sources/`, harvest every function and initializer declaring a parameter labelled `seed` **with a default value** — an initializer under its enclosing type's name, since that is what a call site writes; a required `seed:` is skipped because omitting it does not compile. Over `Tests/`, flag any call to a harvested callable with no `seed:` argument. The project configures the rule itself; there is no list of API names to maintain. **Signatures, not bare names.** Each harvested callable also records its other argument labels, and a call matches only when every label it writes is one that signature accepts. Name-only matching produced **155 findings against BusinessMath, of which 118 were wrong** — 42 from a single collision (`MonteCarloScenario.normal(mean:standardDeviation:numberOfScenarios:seed:)` against the unrelated `ProbabilisticDriver.normal(name:mean:stdDev:)`), the rest calls to `using: &generator` overloads that are seeded by construction. With label matching: **37 findings**, including all 9 genuinely unseeded `MonteCarloSimulation` constructions. A zero-argument call is never flagged — it resolves to some other overload with no `seed:` to pass. **The opt-out requires a reason.** Some tests are about the unseeded path and adding a seed would invert the assertion; BusinessMath has two ("Unseeded runs still integrate correctly", "nil seed is non-reproducible by contract") and both are flagged, correctly, until marked. The marker is `// Justification: …` — `ConcurrencyAuditor`'s spelling for `@unchecked Sendable`, validated by the same `JustificationValidator`. A bare `// Justification:` does not suppress; it changes the diagnostic to say the marker states no reason. The plain `// stochastic:exempt` marker does not suppress this rule at all, because a suppression that costs nothing to write is how a rule becomes noise.
- **`stochastic-determinism` stops skipping `Tests/`, but claims only what nothing else audits**: every visitor method opened with `guard !isTestFile else { return .skipChildren }`, so a test could call `arc4random` or `srand48`/`drand48` and no checker anywhere in the gate would say a word — non-determinism in a test is not less serious than in `Sources/`, it is more, because the test is the thing that is supposed to tell you when behaviour changed. `Tests/` is now walked (`auditTests: true`, settable to `false` to restore the old skip). It is **not** a pure deletion of the guard, for two reasons found while making it. First, `TestQualityAuditor`'s `unseeded-random` already covers `.random(…)`, `.shuffled(…)` and `SystemRandomNumberGenerator` inside `Tests/`, at the same severity — the guard was a documented division of labour, not an oversight, and unskipping wholesale would have put two warnings on one line and taught people to read past both. So in a test file this auditor emits `stochastic-global-state`, and `stochastic-collection-shuffle` restricted to the in-place `.shuffle()` spelling, which is precisely what `unseeded-random` misses by matching the literal name `"shuffled"`. Second, the advice did not survive the move: `stochastic-no-seed` tells you to "accept `inout some RandomNumberGenerator`", which a `@Test` function cannot do because it has no caller to inject one. The two rules that do fire in tests now carry a test-shaped suggested fix — seed a generator locally — while `Sources/` keeps its original wording. First run against BusinessMath's suite: **10 findings**, all `stochastic-global-state`, in four stress-test files that were previously invisible.

- **`fp-equality` detection — two false-positive sources removed, and the blind spot that mattered most**: unifying the rule exposed three defects in the heuristic itself, all now fixed in `FloatingPointRules`. **(1) A static member on a float type is no longer assumed to be a float.** `looksLikeFloatingPoint` treated *any* member access on a `Double`/`Float` base as floating-point, so `Double.dimension == 1` was a finding — `dimension` is an `Int` arriving from a `VectorSpace` conformance. Member access now resolves only against an allowlist of the members that genuinely are the type (`pi`, `infinity`, `nan`, `signalingNaN`, `ulpOfOne`, `greatestFiniteMagnitude`, `leastNormalMagnitude`, `leastNonzeroMagnitude`, `zero`); anything else on the *type* is unknown, and unknown is not floating-point. That allowlist and the sentinel-exemption list overlapped on eight of nine names and disagreed on the ninth, so the exemption list is now **derived** from the allowlist rather than maintained beside it — a static member that *is* the type is by construction a sentinel, since there is no arithmetic behind `.pi` to have rounded. **(2) Name bindings no longer escape their scope.** The name→type map was file-wide, so an `Int` local called `result` was floating-point because an unrelated test in the same file wrote `let result: Double`. Bindings are now scoped to the enclosing function, closure, computed property or type body, innermost-first so an inner binding shadows rather than collides. **(3) Collections of floating-point are operands, and file-local return types make them visible.** `[Double]`, `[Float]`, `Array`/`ArraySlice`/`ContiguousArray` of those, and array literals of float literals now count — `==` on them compares elementwise with `==`, carrying every NaN and signed-zero caveat of the scalar operator — and the diagnostic **says so**, offering `a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }` rather than a scalar form that does not even typecheck against a collection. Reaching the real case also needed **intra-file return-type propagation**: `let a = block(...)` picks up `block`'s declared `-> [Double]`. Deliberately narrow — explicit return clauses only, bare call targets only (`f(x)`, never `receiver.f(x)`), one file only, and a name declared twice with *different* return types is dropped rather than guessed at (two declarations that agree are kept: the answer does not depend on which overload the compiler picks). Also fixed: `x == nil` is an optional-presence test, not a float comparison, and stopped being one the moment `Double?` began reading as a floating-point type. The **division** rule deliberately did *not* widen with the equality rule — it holds a higher evidence bar (annotation, literal, conversion at the site) and does not follow inference chains, because `fp-equality` asks which of three claims an `==` is making while `fp-division-unguarded` asks for a guard in shipping code. Measured on BusinessMath (0 → after): `fp-equality` **0 → 0** as predicted, `exact-double-equality` **0 → 90**, `fp-division-unguarded` **0 → 1**; **nothing previously reported disappeared**, and 11 suppressed-but-detected sites stopped being detected at all — 3 were `T.self == Double.self` (defect 1) and 8 were divisions that only looked floating-point because of the file-wide leak (defect 2). 20 new tests including must-not-fire fixtures written from the real false positives, must-not-fire fixtures for the conservative limits (an overloaded local function, a call to a function declared in another file), and a negative control asserting known-good and known-bad input differ.

- **DocCodeAuditor — `doc-code` (new checker)**: fenced Swift in DocC articles must compile. The checker assembles every checked ` ```swift ` block of an article into **one file-scope program**, in document order, and typechecks it with `swiftc -typecheck` against the built module — so a later block that refers to an earlier binding is *correct* and must keep working, and two independent examples that both open with `let data = …` are *a defect in the article* whose repair is a rename, not an annotation. Diagnostics map back to the **article's** line via marker comments (a location in a deleted temp file is worse than none: it sends someone to edit correct code), and imports duplicating the preamble are **commented rather than removed**, so no offset shifts. The one opt-out is `<!-- docs:illustrative -->` — counted and reported per article, never applied automatically. **Coverage is reported, not assumed**: fences *found* is printed separately from fences *checked*, because an earlier prototype matched fences at column zero, silently skipped blocks nested in list items, and six articles passed with real API drift inside them. **The language mode is read, not guessed** (`ManifestLanguageMode`, SwiftSyntax over `Package.swift`): tools-version default, `.swiftLanguageMode`/`.swiftLanguageVersion`, package-level `swiftLanguageModes`, plus `enableUpcomingFeature`/`enableExperimentalFeature`/`define`/`unsafeFlags`/`strictMemorySafety`/`interoperabilityMode` translated to flags — checking under weaker rules than the build is how an actor method returning a non-`Sendable` type passed for months, and checking under stronger ones hands an older package errors its own build never raises; when the mode cannot be read the checker uses the compiler's default and says so, rather than assuming the strictest. `swift-testing` blocks typecheck (`-F <platform frameworks>` + the `TestingMacros` `-plugin-path`), because a gate that cannot compile a legitimate construct gets worked around and the workaround looks exactly like compliance. Collisions are detected with SwiftSyntax and a scope stack (a `for (name, model) in …` shadows rather than collides; comments are trivia and therefore invisible), `cannot find X in scope` errors are **clustered by symbol** so the headline sizes the repair rather than the cascade, and a `no such module` is reported as a **barrier** rather than as one error among many. `isParallelSafe: true` — which is what orders it *after* `BuildChecker`, since the runner drains the non-parallel-safe phase first; it never writes to `.build` (each article is assembled and typechecked in its own temp directory) and an unbuilt module resolves to `.skipped` with its reason instead of a wall of findings about the gate's own environment. `hermetic`, with cache inputs covering the articles, every first-party source, the built module artefacts and both manifests. **Opt-in** (`--check doc-code` or `enabledCheckers`), and `--full` deliberately does not enable it: unlike `xcode-build` it opts out on *convention*, not cost. Validated against BusinessMath's catalogue — **73/73 articles, 1,305 fences found, 1,219 checked, 86 exempt, 0 errors** — with a mandatory negative control asserting known-good and known-bad input differ. 46 tests. Proposal: `project/plans/completed/DocCodeAuditor.md`.
- **One rule, one implementation, one marker — `fp-equality` and `exact-double-equality` unified**: two checkers implemented exact floating-point comparison independently and had drifted on every axis that matters. `FloatingPointSafetyAuditor` flagged `==`/`!=` wherever either operand *looked* floating-point and honoured `// fp-safety:disable`; `TestQualityAuditor` flagged only `==`, only when a `FloatLiteralExprSyntax` appeared on one side, only inside `#expect`, and honoured only `// TEST-QUALITY:`. Observable result on BusinessMath: `[fp-safety] PASSED` while `[test-quality] FAILED` **on the same lines**, and a site already carrying `// fp-safety:disable` still reported — a developer who read the failing diagnostic, applied the marker it named, and re-ran still failed, because the other checker owned the rule in test files. Detection now lives once, in `FloatingPointRules` (`FloatingPointSafetyAuditor`), and `TestQualityAuditor` delegates to it. What each checker keeps is *reporting* configuration, not a second detector: `fp-equality` stays a warning over `Sources/` and everywhere in a file; `exact-double-equality` stays an error and stays scoped to `#expect`/`#require` arguments (that narrowing is deliberate — it is a rule about what a test claims, not about arithmetic in fixtures and helpers). Coverage is the union: test files now catch a literal-free comparison of two computed `Double`s, which the private copy could not see, and inherit the sentinel exemptions (`0.0`, `.zero`, `.nan`, `.pi`, …), which it did not have — `#expect(z1 == 0.0)` where `sqrt(-2 * log(1))` yields `-0.0` is correct code and is no longer an error.
- **One marker set for that rule**: `// fp-safety:disable` is canonical — it names the rule family rather than a checker — and **both** checkers honour it. `// TEST-QUALITY:` keeps working in both, because 76 sites in BusinessMath alone would otherwise break at once. A marker applies to its own line, and to the line below when it sits on a comment-only line; it deliberately does *not* reach down from a trailing marker, since ~300 inline sites would otherwise start silencing their neighbours. Suppressed floating-point findings are now recorded in `CheckResult.overrides` instead of being dropped, so a marker that suppresses nothing can be found.
- **The suggested fix was confidently wrong, which matters more than the duplication**: the old text — *"Exact equality (==) on floating-point literal. Use tolerance: abs(a - b) < epsilon."* — is bad advice for roughly half of real sites, and following it weakens assertions that were already correct. Three genuinely different claims hide under `==`: computed values where rounding is expected (`abs(a - b) < epsilon`), IEEE 754 equality chosen deliberately (`a.isEqual(to: b)`), and bit-identity (`a.bitPattern == b.bitPattern`, because `==` reports `NaN != NaN` and `+0.0 == -0.0`). The diagnostic now names all three, shortest-and-most-common first, and asserts none. The resolution offered is a **named comparison, never a fourth marker**: a name lives in the code and cannot drift from it, where a marker asserts an intent that can be wrong forever. `isEqual(to:)` and `bitPattern`/`significandBitPattern` comparisons are exempt — flagging them would punish the fix. Per `TestQualityAuditor.md` §6a: a checker's suggested fix is part of its interface, and a confident wrong answer gets followed.

- **standards-watch polish — Federal Register early warning + scheduling**: `standards-watch` now also surfaces **proposed** rule changes before the eCFR text itself moves. A precise Federal Register API query (`conditions[cfr][title]=45&[part]=164&[type]=PRORULE`) — filtered by CFR reference, not a noisy term search — returns only genuine 45-CFR-164 rulemakings; `FederalRegisterWatch.parse` (pure, tested) keeps just the `Proposed Rule` documents and `mostRecent` selects the latest by publication date. The subcommand prints the count and the latest proposed rule (title, date, URL) as an advisory "not yet in effect — review whether it affects the mapping"; the probe is advisory (host allow-listed to `www.federalregister.gov`, any failure just omits the line). Scheduling artifacts land under `scripts/standards-watch/`: a launchd job (`org.roseclub.quality-gate.standards-watch.plist`, weekly), a wrapper (`run-standards-watch.sh` — archives each run, keeps a `-latest`, appends drift to a `DRIFT.log`, exits non-zero on drift), and a deploy runbook. +3 tests. (Dashboard coverage tile deferred: compliance coverage is tool-global, identical per project, so `compliance --as json` is the right feed for any dashboard rather than a per-project tile.)
- **`quality-gate standards-watch` — upstream drift detection (RegulatoryControlMapping Phase 3, the initiative's capstone)**: turns silent drift in a published standard into a dated, gate-visible alert. **Detect and alert only** — it never edits a catalog; a human reconciles and re-stamps. HIPAA is fetched from the **eCFR versioner API** (`api.ecfr.gov`, §164.312 of Title 45) — the API normalizes the date out of the returned content (`_SUBSTITUTE_DATE_`), so the SHA-256 of the section text is stable day-to-day but changes the moment the rule is amended, which is exactly the drift signal; the adapter fills a `{date}` placeholder in the catalog's `sourceRef` with today's UTC date so amendments surface once effective. SOC 2 and ISO are copyrighted and not machine-readable, so they surface as `manual` (re-verify against the cited source). New `StandardsWatch.classify` (pure, deterministic over an injected `StandardsSource` — `unchanged`/`drifted`/`seeded`/`manualReviewOnly`/`unreachable`) and `StandardsWatch.run` (a source error yields `unreachable`, never fails the batch); new `ControlCatalog.upstreamHash` (the last-observed upstream hash, distinct from `contentHash`). The HIPAA catalog is **seeded and armed** — validated end-to-end (seed → unchanged), and drift now exits non-zero for a cron/launchd job to alert on. Runs as scheduled network I/O, never in the gate's enforcement path. +7 tests. Proposal: `02_IMPLEMENTATION_PLANS/PROPOSALS/RegulatoryControlMapping.md`.
- **Control mapping — SOC 2 & ISO 27001 catalogs (RegulatoryControlMapping Phase 1 complete)**: the mapping now spans three frameworks. Two new bundled catalogs — **SOC 2** (AICPA Trust Services Criteria: CC6.1/CC6.6/CC6.7/CC7.2/CC8.1/PI1.1/P1.1) and **ISO/IEC 27001:2022 Annex A** (A.8.24/A.5.14/A.8.15/A.8.25/A.8.28) — each storing only control IDs + **our own paraphrase** + citation, never the verbatim copyrighted text (HIPAA, being public law, stays verbatim). The rule→control mapping is consolidated cross-framework: the crypto/keychain rules now satisfy HIPAA §164.312(a)(2)(iv) + SOC2 CC6.1 + ISO A.8.24 at once, transport rules span three frameworks, logging rules map to CC7.2/A.8.15, the fp/concurrency rules to PI1.1 (processing integrity), the force-* rules to A.8.28 (secure coding), and `privacy-manifest` to SOC2 P1.1 (privacy notice). Change management (CC8.1) and the secure-development lifecycle (A.8.25) surface as **evidence-only** — the gate's own operation is the evidence — demonstrating all four coverage states. `quality-gate compliance` now reports 12 enforced, 2 evidence-only, 2 out-of-scope across HIPAA/ISO/SOC2; the `control-mapping` checker validates all three catalogs clean. +1 test.
- **`quality-gate compliance` — the honest control-coverage report (RegulatoryControlMapping Phase 1)**: a new subcommand that renders the SOC 2 / ISO 27001 / HIPAA technical-control coverage matrix from the bundled mapping. `ComplianceCoverage.matrix` classifies every control into one of four honest states — `enforced` (a real registry-known rule enforces it, listed), `evidence-only` (the gate's own operation is the evidence), `out-of-scope` (beyond static analysis, **listed not hidden**), and `gap` (statically checkable but not yet mapped) — and a phantom-rule mapping never manufactures coverage. `ComplianceReport` renders it as `terminal` or `json`, every rendering leading with the disclaimer that this is *coverage, not an assertion of compliance* — the trust anchor and liability shield. On the shipped HIPAA §164.312 slice: 2 enforced (encryption/decryption, transmission security), 2 out-of-scope (audit controls, integrity). CLI: `quality-gate compliance [--as terminal|json]` (`--as`, not `--format`, to avoid the root command shadowing the child option). +9 tests. Proposal: `02_IMPLEMENTATION_PLANS/PROPOSALS/RegulatoryControlMapping.md`.
- **ControlMapping — `control-mapping` checker goes live (RegulatoryControlMapping Phase 0 complete)**: the SOC 2 / ISO 27001 / HIPAA technical-control mapping is now a running checker. It loads three bundled JSON resources — a **curated rule-ID registry** (all 198 rule IDs the gate can emit), framework **catalogs** (`*.catalog.json`), and the rule→control **mapping** (`*.mapping.json`) — via `Bundle.module` (quality-gate's own reference data, never read from the audited project), and validates the mapping's integrity: a mapping to a rule absent from the registry is an error (phantom rule), a control ref no catalog resolves is an error (phantom control), a `superseded` catalog is an error (upstream drift awaiting reconcile), and a catalog past its freshness horizon is a warning. The first vertical slice ships the **HIPAA §164.312** catalog (verbatim public-law text): transmission security and encryption/decryption as `partial` (mapped to `keychain-secrets`, `security.insecure-keychain`, `security.hardcoded-secret`, `security.weak-crypto`, `security.insecure-transport`, `security.tls-disabled`), with audit controls and integrity honestly marked out-of-scope for static analysis. The validator never asserts "compliant" — only mapping integrity. Registered in the CLI roster; dogfoods `PASSED` on this repo. +4 tests (14 total). Proposal: `02_IMPLEMENTATION_PLANS/PROPOSALS/RegulatoryControlMapping.md`.
- **PrivacyManifestChecker — `privacy-manifest` (new checker)**: verifies an app bundle ships a well-formed `PrivacyInfo.xcprivacy` (a missing/malformed manifest is an automatic App Store rejection, discovered at submission-time otherwise). Second checker of the security slice feeding the forthcoming RegulatoryControlMapping layer (maps to HIPAA Privacy §164.502 / SOC2 Privacy / the Apple App Store privacy requirement). **Opt-in by detection** — the checker acts only when it *positively* identifies an app target (an `Info.plist` carrying `CFBundleExecutable` + `UILaunchScreen`/`UIApplicationSceneManifest`, an `.xcodeproj` declaring `com.apple.product-type.application`, or an explicit `appTargets` config entry); a pure SPM library is `.skipped`, biasing the risk toward under-flagging because nagging a library for a manifest it never needs would train users to disable the checker (proposal §12). When it acts (v1): a missing manifest or an unparseable one is a `.error` (gate `.failed`); a valid manifest missing an expected top-level key (`NSPrivacyTracking`, `NSPrivacyTrackingDomains`, `NSPrivacyCollectedDataTypes`, `NSPrivacyAccessedAPITypes`) is a `.warning`; empty arrays are fine. File scans skip hidden trees (`.build`/`.git`) so vendored Info.plists don't misfire app-detection. New `PrivacyManifestConfig` (`appTargets`/`requireTopLevelKeys`, decoded from a `privacy-manifest:` section). Full required-reason API cross-referencing is deferred to v2 (composes with the `UserDefaults` detection the KeychainSecretsChecker already needs). Wired into the CLI roster; dogfooded as `SKIPPED` on this library repo. 7 tests. Proposal: `02_IMPLEMENTATION_PLANS/PROPOSALS/PrivacyManifestChecker.md`.
- **KeychainSecretsChecker — `keychain-secrets` (new checker)**: flags credentials/tokens written to `UserDefaults` (a plaintext `.plist` inside the app container — unencrypted at rest and swept into device backups) and points the developer at the Keychain. First checker of the KeychainSecretsChecker/PrivacyManifestChecker security slice that feeds the forthcoming RegulatoryControlMapping layer (it maps to SOC2 CC6.1 / ISO A.8.24 / HIPAA §164.312(a)(2)(iv)). Detection is **AST-based** (SwiftSyntax), two-pass: pass 1 records identifiers bound to a `UserDefaults` instance (by initializer `UserDefaults.standard` / `UserDefaults(suiteName:)` or a `: UserDefaults` type annotation) so a later `defaults.set(...)` resolves to a real receiver rather than a same-named method on something else; pass 2 detects `set(_:forKey:)` / `setValue(_:forKey:)` calls and `defaults[key] = value` subscript assignments whose key literal or stored-value identifier names a secret. Precision guards from the proposal's §12 adversarial review: a stored `Bool`/`Int` literal short-circuits to no finding (a stored `true`/`3` is not a credential, so `set(true, forKey: "hasSeenTokenTutorial")` stays quiet), matching is **word-aware** via camelCase/acronym tokenization (`tokenizer` ≠ `token`; `apiKey`→`apikey` still matches as a compound), a string-literal secret key gates at the configured severity (default `.error`) while a match seen only in the value's identifier softens to `.warning`, and both a config `allowKeys` list and an inline `// keychain:exempt` marker (recorded as a `DiagnosticOverride`, never silent) suppress a site. New `KeychainSecretsConfig` (`severity`/`allowKeys`/`extraPatterns`, decoded from a `keychain-secrets:` section). Wired into the CLI checker roster and end-to-end validated (flags a real `authToken` write at error, leaves the adjacent Bool line alone). 14 tests. Proposal: `02_IMPLEMENTATION_PLANS/PROPOSALS/KeychainSecretsChecker.md`.
- **On-device narrative fallback (Apple Foundation Models)**: the pulse narrative keeps **Claude Sonnet as the primary engine** and gains an offline/no-key **fallback** that runs entirely on-device via Apple's Foundation Models — filling the `LLM > preserved-LLM > template` durability chain the handoffs specified but never shipped. New `NarrativeCore` target introduces a provider seam **above** prompt construction (the two engines can't share a prompt: the whole-pulse prompt is ~69.5k tokens against Foundation Models' 4,096-token window): `NarrativeChain` tries **Claude → on-device → preserved** in order, and `GenerateNarrative` exposes `--provider auto|claude|on-device|preserved` (default `auto`) plus `--per-project/--no-per-project`. The on-device provider **shards the pulse per project** (`ProjectSharder`, each ≤~715 tokens) and reduces to a portfolio narrative from **deterministic fact-lines** — this content tokenizes at ~1.9 chars/token, so feeding the reduce model-generated leaves overflowed the window; deterministic lines fit reliably (~2,600 tokens), guarantee every project a clean PASS/score entry, and make the portfolio narrative a single ~30s call. **Per-project narratives are now a rule**: the map step writes one grounded document per project to `pulse/<label>/projects/<id>.md`, on-device and free. Output is `sanitize()`d against the 3B model's occasional hallucinated `tool_call:` syntax, with a deterministic fact-line fallback when a leaf produces nothing usable; a single project's model error can't fail the whole run. The Claude prompt is ported **verbatim** into `PortfolioPromptBuilder` (behavior unchanged); frontmatter records the producing `source:`. Foundation Models is gated behind `#if canImport(FoundationModels)` + `@available(macOS 26)` so the package still builds on the x86_64 server where the framework is absent. 40 tests; auditors 0/0; on-device path validated end-to-end (portfolio + 56 per-project docs, zero artifacts) against a temp corpus copy. Remaining quality upgrade: guided generation (`@Generable`) for per-project prose. Proposal: `02_IMPLEMENTATION_PLANS/PROPOSALS/OnDeviceNarrativeFallback.md`.
- **Guided generation for the on-device narrative (`@Generable`)**: the remaining quality upgrade the on-device fallback flagged. `SystemLanguageModelGenerator` now drives the model with **constrained decoding** against a `GuidedNarrative` schema (a single markdown `body` field) rather than free-form string generation — so the 3B model's occasional hallucinated `tool_call:` preamble is prevented **structurally**, at the sampling layer, instead of being cleaned up after the fact. The caller's `sanitize()` pass stays as a belt-and-suspenders backstop. Gated behind `#if canImport(FoundationModels)` + `@available(macOS 26)`, so the x86_64 build server is unaffected; NarrativeCore's 40 tests stay green (the map-reduce orchestration is exercised through the generator seam, which is unchanged). Committed in `bd7cc99`.

## [2.0.2] — 2026-07-27

- **Duplication auditor — precision & clone-class grouping (14,000 → 11)**: dogfooded against quality-gate-swift, `duplication.clone` emitted 14,000+ inbox rows dominated by false positives — narrow (85–137 token) matches where two structurally-parallel-but-unrelated blocks collided because the tokenizer collapsed *all literal content* to a single `LIT` sentinel (e.g. an ADR-YAML test and a `Package.swift` test, entirely different data, reduced to a byte-identical token stream). Four fixes, on two axes. **Precision:** `CloneTokenizer` now normalizes only identifiers (→`ID`) and keeps literal content **verbatim**, so a genuine copy (which preserves its literals) is distinguished from isomorphic-but-distinct code that merely shares Swift's grammar — this alone breaks the entire "same shape, different data" false-positive class while preserving renamed-*identifier* detection; a new `DuplicationConfig.minDistinctTokens` (default 12) diversity floor drops low-variety boilerplate; `minTokens` default rises 80 → 175 (only substantial duplication surfaces); `excludeTests` defaults to `true` (parallel test structure is good design). **Presentation:** the auditor reports one diagnostic per **clone class** — all maximal blocks sharing an identical normalized sequence grouped and named in one row (`222-token clone across 3 sites: A ≈ B ≈ C`) — instead of `N·(N−1)/2` pairwise rows, so a skeleton shared across 10 auditors is one finding, not 45. Result on this repo: 14,000+ rows collapse to **11**, each a genuine 189–405-token clone (real auditor scaffolding worth refactoring), zero test-boilerplate noise. Advisory posture unchanged (`.note` unless `warnOnClones`). Proposal: `02_IMPLEMENTATION_PLANS/PROPOSALS/DuplicationPrecisionAndGrouping.md`.
- **Dashboard gate status is now composite, and the GUI refreshes**: the portfolio overview and the project drill-down could disagree — a project fixed with a targeted `--check` re-run showed green in its Checkers/Inbox tabs but still `✗` in the overview, because the overview counted only full standard runs while the detail read all runs. The overview now derives from the same per-checker composite the drill-down uses (`ProjectSummary.gateStatus`): every checker's most recent *standard-mode* result (a targeted subset run counts; advisory surveys never do). Green assembled from partial runs renders distinctly — `✓*` / `pass*` / "PASSING *" (yellow) — from `✓` confirmed by one full gate (`latestFullPassed`), so a subset-run green is honest without being lost. The findings **Inbox** is likewise composite over standard runs (each checker's latest), fixing a latent case where an `--advisory-all` survey could flood it with downgraded gating findings. The macOS **GUI dashboard** now auto-refreshes on the CLI's 30-second cadence — change-gated by a cheap corpus mtime signature (`DashboardLoader.corpusSignature(at:)`) so an idle poll is a stat, not a re-parse, and reloads are silent (no spinner, selection preserved) — plus **File ▸ Refresh (⌘R)** for an immediate reload.
- **Held-operation spool (3b)**: a governed write that goes `.held` now persists its artifact byte-faithful (`HeldOperationStore`, one JSON per review id) until the review is decided — `GovernedWriteHandler.resolve(reviewID:)` applies the ORIGINAL operation on approval, discards on rejection, waits on pending, and is idempotent. A spool failure downgrades the hold to a rejection: accepting a governed write we could not preserve would be worse. "Held, never lost" is now a claim about the artifact, not just the review record. Next: the corpusd daemon shell (see `05_SUMMARIES/2026-07-12_HANDOFF.md`); HTTP binding pending the roseclub toolchain parity check.

## [2026.07.12] — 2026-07-12

Second pinned binary release (arm64/x86_64). Contains Phases 4a–4d, 3a complete, and the first 3b slice.

- **Phase 4**: swift-vigil extraction (public, MIT — temporal determinism, flip detection, stress analysis, cancellation checkpoints; the monolith consumes VigilKit), the Tier-2 plugin overlay (contract in quality-gate-types 1.2.0/1.3.0; vigil as first consumer; PluginRunner/PluginChecker with advisory-by-default trust rules), Tier-1 declarative custom rules (`customRules:` in `.quality-gate.yml` — line regex, include/exclude globs, `// custom:exempt` recorded not silent, `origin: custom-rule`, gating by each rule's declared severity), `--advisory-all` trial mode with `gateMode` honesty, the decaying baseline (`quality-gate adopt`, content-hash matched, everything expires), and `orient --as html` (self-contained shareable report). Full entries at phase completion.
- **Phase 4c major-points parity ("replace, don't add")**: the substitutional strategy — adopting quality-gate means dropping a tool, not adding one.
  - **IdiomAuditor** (new checker, `idiom`): the head of SwiftLint usage as 20 native rules (empty-count, redundant-syntax family, syntactic sugar, shorthand operators, identifier/type naming, TODO-ticket policy, file/function/line length, whitespace family, unused closure parameters, implicit getter, redundant String enum values, legacy-random, contains-over-first). Advisory posture — notes by default (`escalateToWarning` config-tunable up; the gate blocks on correctness, not whitespace); safe-subset `suggestedFix`es with round-trip tests (fix → reparse clean → rule silent); `// idiom:exempt` recorded as an override, never silent. 82 tests.
  - **`quality-gate import-swiftlint`** (new subcommand): reads `.swiftlint.yml`, emits a `.quality-gate.yml` fragment — enabled rules mapped to native equivalents (with thresholds carried over), `custom_rules` translated verbatim to Tier-1 `customRules:`, and the honest unmapped report for the tail, both in the terminal and as comments in the fragment itself. Golden tests over minimal/typical/heavy-custom fixtures.
  - **DuplicationAuditor** (new checker, `duplication`): Sonar-parity clone detection — normalized token-stream sliding-window hashing (identifiers→ID, literals→LIT, so renamed-identifier clones match), maximal-block pair merging, deterministic FNV-1a (never `String.hashValue`). Advisory by default (`warnOnClones` escalates). `CloneFingerprint` API (robust winnowing) ships ready for the cross-project corpus join — the thing Sonar can't see across separate repos. 10 tests.
  - **SmellPack** (new checker, `smells`): parameter-count, nesting-depth, god-object (same-file extensions count), type-length, closure-length as advisory notes stating measured value and threshold; `// smell:exempt` recorded. Strictly-over semantics with N/N+1 boundary tests. 17 tests.
  - **Baseline burn-down** (CorpusKit 1.11.0): runs that applied a ledger stamp `BaselineSnapshot` (baselined/expired/newFindings) into telemetry — defaulted optional, not a schema bump — and the dashboard project detail renders the debt line with its burn-down trail ("42 → 38 → 31"), expiry rendered louder than coverage.
- **Phase 3a — service-free trust plumbing (CorpusKit 1.12.0)**: every piece improves the solo experience and costs nothing if the demand-gated service (3b) never fires.
  - **`CorpusTransport` + `.direct`**: the seam 3b's service slots into. `DirectCorpusTransport` delegates verbatim to `TelemetryWriter` (artifacts indistinguishable — no corpus migration, no caller rewrite later); every corpus caller in the monolith (telemetry emission, skip recording, calibrate, telemetry-push, pulse/narrative generation, consistency checker, policy discovery, MCP tools) now speaks the protocol.
  - **Fail-open spool (§8, the pulled-network guarantee)**: `SpoolingCorpusTransport` wraps any transport — enforcement-path writes (metadata, work events, skips) that fail spool to `~/.quality-gate/spool/` and the gate completes normally; each emission drains the spool first (timestamp-ordered, idempotent replay). corpusd will never be in the enforcement path, stated as a test.
  - **Re-verify queue (§7, solo Judgment Workbench)**: `quality-gate re-verify` lists expired baseline debts and takes the two conscious decisions — `--re-affirm` (re-dated, expiry pushed out, **attributed by name** via the new `reAffirmedBy` field; legacy ledgers decode without it) or `--retire` (record removed; a still-present finding gates on the next run). Nothing is silent, everything ages — now with a workflow, not just a warning.
  - **Findings inbox + calibrate form (§7, 3a complete)**: the dashboard grows from display to workbench. The project detail gains an **Inbox** tab — the latest run's advisory findings, acknowledgeable in place: Enter prompts for the reason and *writes the marker line at the flagged location* (`JudgmentWorkbench`: rule→marker registry verified against each auditor's detection code — `idiom:exempt`/`smell:exempt`/`custom:exempt`/`concurrency:exempt` end-of-line, `legibility:reserved <reason>` on its own line above; golden re-audit tests prove finding → acknowledged → override recorded). The **calibrate wizard** (`c` key) walks the seven JudgmentCalibration fields and writes the MCP tool's exact artifact through the corpus transport — judgment is now human-reachable, not just assistant-reachable. Text-entry sessions own the keyboard (a typed `q` types, never quits).
- **Phase 3b activated — the tripwire fired for real**: `quality-gate[bot]` (verified CI writer, Phase 2 identity) has been committing Iconquer telemetry to the corpus since July 4 — the second distinct writer the demand gate was watching for. First 3b slice ships the trust machinery ahead of the daemon:
  - **`CorpusService`**: `TokenStore` (random 32-byte bearer tokens shown once at issuance, stored SHA-256-hashed, `SecRandomCopyBytes` entropy; issue/verify/revoke/list), `IdentityEnvelope` (verified token → CI identity → asserted claims, precedence tested), and the **review-semantics state machine** — `ReviewPolicy` (glob rules; `requiresSecondReviewer` wins over `selfAcknowledgeAllowed`; absent policy = today's solo behavior exactly) + `ReviewQueue` (governed overrides hold as `pending-review`; approve/reject require a *distinct* second identity — the submitter approving their own override is a typed error).
  - **`quality-gate corpusd-token issue|revoke|list`**: token lifecycle CLI, live now so credentials exist the day corpusd does. Issue prints once; list shows names + hash prefixes only; the raw token never touches disk (test-asserted).

## [2026.07.10] — 2026-07-10

First pinned binary release (arm64/x86_64, for quality-gate-action). Contains everything below this heading through Phases 0–2.

- **Phase 2 CI parity (workstreams 2.1–2.5)**: enforcement that travels — one canonical run path for hook, manual, and CI, with parity proven byte-for-byte rather than promised.
  - **2.1 `quality-gate ci` + verified identity** (`fa155b7`): `CIRunPlan` is the determinism contract as a value — no index build unless the workflow opts in, cache off, UTC, strict by default, SARIF + JSON summary artifacts always. The subcommand re-enters the standard run path via the same parse the CLI uses (parity by construction). CorpusKit 1.8.0 adds `CIIdentity` — the first provider-verified identity in the ecosystem — plus `host` attribution for asserted runs; telemetry records both. Passthrough is `--checkers` (ArgumentParser matches parent options after subcommand names, silently shadowing a same-named child `--check` — observed, documented in code).
  - **2.2 The parity harness** (`fa155b7`): local manual run and `ci` run of a findings-producing fixture yield byte-identical SARIF after path normalization; consecutive `ci` runs byte-identical. The phase's acceptance criterion, in the suite permanently.
  - **2.3 CI-native telemetry push** (`656aaa1`): `ci --corpus-remote <url>` clones the corpus, points telemetry at the clone, publishes after the run (add → commit → pull --no-rebase → push). Explicitly interim — the merge noise is the measured case for Phase 3's service. Hook-leak `GIT_*` variables scrubbed; deploy-key transport preserved; red runs publish too, then rethrow (fail-open). The ProcessSafetyAuditor caught a real 64 KB pipe deadlock in this code's first commit attempt.
  - **2.4 Second-writer tripwire** (`27ac49a`): CorpusKit 1.9.0's `WriterCensus` — two distinct *persons* (verified CI actor, else asserted owner) within 30 days trips a standing warning in every gate run and the dashboard: "Phase 3 controls required." Machines are surfaced but never trip alone (the owner's own multi-Mac setup is not a transition). Warning-only, by design.
  - **2.5 Distribution scaffolding** (`a805cf6`): `Scripts/release.sh` builds, signs, and publishes pinned per-arch release artifacts from our own hardware (GitHub Releases is distribution, never build infrastructure); the self-adoption workflow ships `workflow_dispatch`-only until a self-hosted runner is registered (a push trigger with no runner reads as failure). The composite action lives in the sibling `quality-gate-action` repo (scaffolded, local commit `29ad0cb`), README leading with the 10× multiplier warning and the self-hosted recipe per §3b/§3c.
- **Phase 1 overlay model (workstreams 1.1–1.4)**: the gate now works on repositories you don't control — the contributor persona (Ignite-style open-source work) is unlocked, with the read-only guarantee enforced structurally rather than promised.
  - **1.1 Layered config resolution** (`b1dfc90`): `ConfigResolver` merges repo `.quality-gate.yml` → overlay `config.yml` → user-global `config.yml` → built-in defaults, first hit per top-level section, sections atomic (a repo's declared policy always wins wholly). Merging happens on raw YAML nodes, so future config sections inherit overlay support with zero per-field plumbing. `OverlayStore` owns the `~/.quality-gate/` layout (`QUALITY_GATE_HOME` override; identity-sanitized overlay dirs). New `quality-gate config [--explain]` prints per-section provenance — "which config am I running?" now has a one-command answer. Main run and `doctor` resolve through the same seam.
  - **1.2 RunEnvironment + WriteGuard** (`b650699`): foreign runs redirect every write (legibility artifacts, result cache) into the overlay; `validateWrite`/`WriteGuard` trap any in-repo write with traversal-safe whole-component path matching (`QG_FOREIGN_REPO_ROOT` backstop for deep writers, new `QualityGateError.writeGuardViolation`). Auto-detection: no repo config + existing overlay → foreign; `--foreign`/`--resident` force. `--fix` refused foreign. Foreign telemetry silent unless the overlay itself configures the corpus. Resident runs byte-for-byte unchanged.
  - **1.3 `quality-gate orient`** (`16c0265`): zero-config onboarding map for any Swift package — reading order, module cards with roles labeled "(inferred)", package composition ("Built from"), watermarked when the repo declares no config of its own; `--output` refuses to write inside such a repo. `READMELeadExtractor` completes the what-it-does chain (description comment → Master Plan Mission → README lead) for orient and dashboard cards alike. Dependency-less targets are now graph nodes, so single-module packages produce a real reading order. Never compiles the analyzed project (`QG_NO_INDEX_BUILD` always set; `--semantic` reuses an existing store only).
  - **1.4 Foreign telemetry + automated acceptance** (`8affafd`): foreign runs record under the upstream identity with `identityKind: foreign` (CorpusKit 1.7.0 — defaulted field, not a schema bump; pre-Phase-1 artifacts decode as `resident`). `ForeignModeAcceptanceTests` exercises the shipped binary against fixture upstreams: pristine `git status --porcelain`, artifacts in the overlay, silence without overlay corpus config (even against a user-global corpus path), orient end-to-end with watermark, `--fix` refusal, and resident behavior unchanged.
- **Phase 0 core hardening (workstreams 0.2, 0.3, 0.5, 0.4, 0.1, 0.6)**: the professionalization roadmap's foundation layer, built TDD-first with each workstream gate-clean.
  - **0.2 Config plumbing** (`66f5867`): CLI overrides now flow through one testable seam — `CLIOverrides` + `Configuration.applying(_:)` mutate exactly their own fields instead of reconstructing `Configuration` memberwise. The RED test reproduced the shipped bug class: both reconstruction sites clobbered nine config sections back to defaults, and the `--threshold` override reset four complexity fields. All top-level config properties are now `var`; `ConfigurationOverrideIsolationTests` proves override isolation with an all-38-sections-non-default fixture.
  - **0.3 CorpusKit extraction** (`25a409f`): corpus schema + I/O consolidated into the new `quality-gate-corpus-kit` package (one `CorpusPath`, one `TelemetryWriter`, one artifact model set; 284 tests moved with their code). `IJSSensor`/`IJSAggregator` remain as `@_exported` shims so imports stay source-stable; −7,581 lines here. Drift between the two prior copies is reconciled in CorpusKit's `DRIFT.md`. The org-judgement-system half of the cutover lands separately once its tree quiets.
  - **0.5 Corpus schema versioning** (CorpusKit 1.1.0–1.2.0): every corpus artifact now conforms to `VersionedCorpusArtifact` and stamps `schemaVersion` on write. `CorpusSchema.decode` applies one reader policy — tolerant-older, skip-newer-with-logged-note, garbage-still-throws. Adopting the pilot on `OrientationReport` fixed a live data-loss bug: pre-E1 orientation artifacts were silently skipped as "malformed."
  - **0.4 Stable project identity** (`d364faa`, CorpusKit 1.3.x): `ProjectIdentity` resolves explicit config → normalized git remote (`org__repo` slug; forks distinct by construction) → basename fallback with a logged weak-identity notice. The corpus manifest gains an `aliases:` map and readers union identity + aliased dirs — history is never moved. New `migrate-corpus-identity` subcommand proposes aliases (dry-run by default; `--apply` writes only `manifest.yml`). Write-side `consistency.useRemoteIdentity` ships default-OFF for one release.
  - **0.1 Telemetry emission unification** (`8c2ffb8`, CorpusKit 1.4.0, schema v2): one post-run step, `TelemetryEmission.emit`, fires on every configured invocation — `--check <subset>` runs are now recorded, tagged with `runScope`. Statistics stay honest: `ProjectSummary` pass rate / latest status count full runs only, per-checker rates include subsets, and the dashboard Runs line shows `N full (+M partial)`. Sidecar emitters (complexity, orientation) run on subsets only when their checker ran.
  - **0.6 Stale-binary self-check** (`d267a92`, CorpusKit 1.5.0): new `minimumGateVersion` config pin — a binary older than the pin warns, and refuses to run under `--strict`, naming both versions. `quality-gate doctor` prints build identity, config provenance, pin status, and index freshness. Every telemetry emission stamps `gateBuild` (commit + build date), so staleness is visible from the corpus side.
  - Also: the portfolio dashboard's health timeline now honors the `NO_COLOR` convention (`9bb6be1`, flagged by the new accessibility detector; root-cause fix, no suppression).

- **Work-attributed telemetry — data plane (Phase 1)**: the narrative generator could see metrics move but never *why* — the causal record (git commits, CHANGELOG, session summaries) never reached the corpus. This wires that causal record into telemetry. `CheckResultMetadata` gains an optional `commitSHA` join key (backward-compatible decode: legacy metadata without the field still decodes to `nil`). A new `WorkEvent` value type (`IJSSensor`) captures per-run git provenance — the `HEAD` SHA, commit subjects new since the last recorded entry, and optional CHANGELOG-delta / newest-session-summary text. `TelemetryWriter` gains `readWorkLog` / `writeWorkEvent`, which upsert idempotently by `(calendar-day, commitSHA)` into a single per-project `work-log.json` (`CorpusPath.workLogPath`), kept sorted by date. Provenance capture lives in `GitProvenance` (`QualityGateCore`, reusing `ProcessRunner`) and degrades gracefully — a non-git dir, missing `git` binary, or any subprocess error yields all-`nil`/empty and never throws. The gate wires this into its telemetry-emit path: it reads the last recorded SHA, captures provenance for the gated project dir, stamps `commitSHA` onto the metric snapshot, and upserts a `WorkEvent` — all best-effort, so a provenance or work-log failure can never fail the gate. Consumption lands in Phase 2 (below).

- **Work-attributed telemetry — narrative consumption (Phase 2)**: `generate-narrative` now reads the per-project work-logs and lets the narrative attribute metric movements to the work that produced them. `run()` loads each pulse project's `work-log.json` (best-effort — a missing/unreadable log is skipped) and a new pure `WorkLogFormatter.recentWorkSection` (`IJSSensor`) renders the in-window events (project, `yyyy-MM-dd`, short SHA, commit subjects, a `[session summary present]` flag) into a "Recent Work" prompt section, returning `nil` — so the section is omitted — when no events fall in the window. The system prompt gains **attribution guardrails**: attribute a movement (trajectory inflection, resolved anomaly, override drop) to a work-event only when their dates and commit SHAs align, phrase it as "coincides with"/"following" (not "caused by") unless a session summary explicitly claims the fix, and never invent a cause for an unattributed change. +5 `WorkLogFormatter` tests (in/out-of-window filtering, all-out → nil, empty → nil, SHA truncation, session-summary flag, project sort order). Until gate runs made by the Phase-1 tool populate work-logs, the section is simply absent — no behavior change to existing narratives. Design proposal `02_IMPLEMENTATION_PLANS/PROPOSALS/WorkAttributedNarratives.md`.

- **LegibilityAnalyzer — advisory whole-codebase legibility (new checker)**: the first checker aimed at goal 2 (legibility), not goal 1 (correctness) — every existing auditor is a local-defect detector; nothing asked whether a human can pick up the whole codebase and build a mental model. Advisory-only (mold of `ComplexityAnalyzer`): all findings are `.note`, status is always `.passed`, it **never gates**. Motivated by the SonarSource minimal-pair study (arXiv:2605.20049) — cleanliness barely moved task success but cut agent file-revisitation 34%, and suppression markers had negligible effect (only structure did). Scope is explicitly bounded against the checkers that already own adjacent ground: doc *presence* → `DocCoverageChecker`, *deadness* → `UnreachableCodeAuditor`, *local complexity* → `ComplexityAnalyzer`; this owns only navigability of *live* code at module scale. Three rules: `legibility.central-unoriented` (a high-fan-in module lacking a DocC overview — coverage ≠ orientation; ranked, top-N), `legibility.module-cycle` (dependency SCCs — no clean reading order), and `legibility.over-public-symbol` (a live `public` symbol referenced only in-module → tighten to `internal`; acknowledged via `// legibility:reserved` / `exemptSymbols` and surfaced as a `ComplianceRecord`, not dropped — flag-to-understand, not forbid). Also emits a **reading-order / module-map artifact** (JSON + Markdown under `.build/legibility/`) — the substrate for a future `ONBOARDING.md` and the dashboard's module-orientation section. Runs on the *declared* `Package.swift` graph (drives orientation + cycles + reading order; test targets filtered out), and — when a fresh index store is present — an **IndexStore semantic pass** upgrades that to real reference-weighted fan-in and enables the over-public rule; it degrades cleanly to declared-graph mode when the index is missing or stale. The over-public rule is scoped to public *types* (a public member of a public type is part of that type's contract, not an independent over-exposure) and only queries references for public symbols (cross-module use is only ever of the public surface). Dogfooded end-to-end on this repo: 39 public types used only in-module surface as over-exposed (including several of the analyzer's own — the check catching its own over-exposure), while `IJSSensor`/`IJSAggregator`/`IJSDashboardCore` remain the central-but-unoriented modules. Pure core is fully unit-tested — `ModuleGraph` (iterative Tarjan SCC, fan-in-weighted reading order), `PublicSurfaceScanner`, `SemanticGraphBuilder`, the three rules, the map builder/renderer, and the declared-graph loader (51 tests). Dogfooded on this repo: `IJSSensor` (fan-in 10), `IJSAggregator` (7), `IJSDashboardCore`/`IJSRefiner` (3) surface as the central-but-unoriented modules. Design proposals `02_IMPLEMENTATION_PLANS/PROPOSALS/LegibilityAnalyzer.md` and `DashboardModuleOrientation.md`.
- **TestRunner — deliberate stress mode for timing-tagged tests (new)**: Rule 3 (final) of the Concurrency Gate Tightening proposal. Flip detection (Rule 2) is *passive* — it waits for a race to surface across commits; stress mode *provokes* one. Tests carrying a `// TIMING:` comment are self-identifying stress candidates (teardown-liveness bounds, reconnect budgets, phase-sync). When `stress.runs > 1`, TestRunner scans `Tests/` for the marker (`TimingTestScanner`, SwiftSyntax-based so a `// TIMING:` inside a string literal or a trailing body comment does **not** tag anything — the accidental version of this, parallel package gates saturating cores, is what caught the original harbor race, now made deliberate), re-runs *only* the tagged tests N times — optionally under a background CPU-contention harness sized to `cores − 1` — and flags any test that was **not unanimous across the identical runs** (`stressFlips`). Since every run shares one commit + source, a non-unanimous outcome is a *definitive* race (stronger than a cross-commit flip); the `test.stress-flip` diagnostic carries the pass/fail tally. Per-release / nightly cadence: `runs: 1` (default) is a zero-overhead no-op, and no tagged tests → a single `.note`, no extra runs. New `StressTestConfig` (`runs`/`contention`/`strict`/`marker`). +14 tests (marker scanner: Swift Testing + XCTest tagging, string-literal and body-comment exclusion, non-test exclusion, multiple, custom marker; intra-batch analysis: unanimous-pass/‑fail non-flips, mixed flip with tally, isolation, <2-roster guard; diagnostic severity + framing). Design proposal `02_IMPLEMENTATION_PLANS/PROPOSALS/ConcurrencyGateTightening.md` — all three rules now landed.
- **TestRunner — test-outcome flip detector (new)**: Rule 2 of the Concurrency Gate Tightening proposal, and the highest-leverage of the three. The gate runs the suite on every commit but each run is otherwise memoryless — it can't tell "passed last time, fails now, no source change" from "always fails." The detector persists a per-package roster after each `test` run (`.build/quality-gate-cache/test-outcomes/`, mirroring `ResultCache`'s corruption-safe/best-effort posture) and, on the next run, flags any test whose pass/fail outcome **flipped while the package fingerprint is unchanged** — scheduler-dependent behavior, not a code change. This is exactly the class of race the harbor stop-vs-completed bug was: the 2-consecutive-clean-runs flake policy correctly passed it (it *was* clean twice), but a single flip against a byte-identical package is the alarm. The `test.outcome-flip` diagnostic names both commits so the regression window is bounded, and is framed "scheduler-dependent behavior detected — find the window" rather than "flaky test." Pieces: `TestRunner.parseTestRoster` (full pass/fail roster — Swift Testing *and* XCTest — where the old parser extracted only failures); `TestOutcome`/`TestRunRecord`/`FlipDetector`/`TestOutcomeStore` in QualityGateCore; wired into `TestRunner.check` behind `FlipDetectorConfig` (`enabled` default true, `strict` raises a flip from `.warning` to `.error`). A changed package fingerprint suppresses flips (an outcome change is then expected); an empty roster (build failure → no tests ran) never overwrites the stored history; all state IO is best-effort. +23 tests (flip detection incl. both directions, package-change suppression, suite-scoped keys, Codable round-trip; roster parsing for both frameworks incl. Suite/started/issue-line exclusion; store round-trip/corruption/overwrite/isolation; diagnostic severity + framing; orchestration incl. the empty-roster guard). Design proposal `02_IMPLEMENTATION_PLANS/PROPOSALS/ConcurrencyGateTightening.md` (Rule 3 — timing-tagged stress mode — remains a follow-up).
- **ConcurrencyAuditor — `cancellation-checkpoint-after-loop` (new rule)**: flags a `for await` / `for try await` loop, inside a function that already treats cancellation as semantic (uses `Task.checkCancellation()` or `Task.isCancelled`), that is followed by exit-reason-dependent code with **no** post-loop cancellation check. Motivated by a real production race in `harbor`: a user-initiated *stop* was mislabeled a *completed* session because a cancelled `for try await` on an `AsyncThrowingStream` **ends quietly** (the iterator returns `nil`) rather than throwing `CancellationError` — a third loop-exit path the author never specified — so the post-loop `session.markCompleted()` ran on the cancelled path too. The defect survived Design-First TDD and 3+ green gate cycles and only surfaced when parallel package gates accidentally stress-loaded the scheduler. Detection is **AST-based** (SwiftSyntax), not regex: it requires knowing the enclosing-function body boundary, walking the loop's following siblings in control-flow order (skipping `defer`), and distinguishing a real `Task.checkCancellation` call / `Task.isCancelled` read from the same words in a string or comment. A `guard !Task.isCancelled`, `if Task.isCancelled`, or `try Task.checkCancellation()` immediately after the loop satisfies the rule; scoping to functions that already use a checkpoint keeps false positives near zero. Escape hatch: `// concurrency:exempt` on the loop line (recorded as a `DiagnosticOverride`). Severity is `.warning` by default, `.error` under `ConcurrencyAuditorConfig.cancellationCheckpointStrict`. +10 tests (the harbor shape, `isCancelled` variant, `defer`-before-dependent-code, checked/guard-checked tails, no-checkpoint-function control, plain-`for` control, defer-only tail, exempt marker, default severity). Design proposal in `02_IMPLEMENTATION_PLANS/PROPOSALS/ConcurrencyGateTightening.md` (Rule 1 of 3; the test-outcome flip detector and timing-tagged stress mode are follow-ups).
- **Dashboard group detail — navigation fix, richer member table, group status block**: three fixes from field notes. **(1) Navigation:** `Enter` on a group member opened a *blank window* — the handler mapped the member to a portfolio row via `visibleRows`, but a collapsed group has no such row, so `selectedIndex` stayed on the group row and the detail view resolved a `nil` subject. Fixed with an explicit `DashboardState.detailProjectID` set on every drill-in (portfolio and group); the app resolves project detail from it. `→`/`Enter` now open the selected member's Project Detail, `←` backs out to the portfolio, and a click on a member row selects + opens it. Also fixed a latent order mismatch (the view lists members sorted by projectID while the handler indexed portfolio-sort order, so the highlighted row could open a different project). **(2) Member table:** columns now align to their headers and add **Status** (`ok`/`!!`), **Runs**, **Overrides**, and **Trajectory** (direction + arrow, plus a `z<score>` suffix when the member has a significant anomaly — `StatisticalAnomaly.scope` is the project ID). **(3) Group status block:** a derived Tier (inferred from member tiers) / Quality Score (mean member weighted score, else aggregate pass rate) / Trajectory + Validity, computed by a new pure `GroupInsights` helper (IJSDashboardCore) via OLS over the group's daily snapshots — the pulse pipeline has no native group-level tier/score/trajectory. Design proposal in `02_IMPLEMENTATION_PLANS/PROPOSALS/GroupDetailRedesign.md`. +25 tests (`GroupInsightsTests`, group-drill-in state tests incl. the collapsed-group regression and click hit-testing, member-column and status-block view tests, header-line drift guard). Consistency column was scoped out — no per-project data source without new run-metadata aggregation. Member names middle-elide via `ANSIStringMetrics.elideMiddle` (matching the portfolio list) so both the head and the identity-bearing camel-case suffix survive tight columns (`BioFeedba…Core`).
- **Dashboard project detail — two tabs + arrow/mouse navigation**: the four detail tabs (Overview, Checkers, Trends, Status) are consolidated to **two** — a single scrollable **Summary** page stacking the former Overview stats, the Trends sparkline, and the Status/tier-override sections as titled blocks (`── Trends ──`, `── Status ──`), plus the standalone **Checkers** list. Tab switching moved off `Tab`/`Shift-Tab` (removed) to **`←`/`→` (clamped, no wrap)** and a **left-click on a tab label**; `↑`/`↓` still scroll, `Enter` activates the tier picker from the Summary tab, `Esc` goes back. A new `DetailTabBar` helper is the single source of truth for tab-bar geometry, so the drawn labels and the clickable column ranges cannot drift (`ProjectDetailTUIView.renderTabBar` and `DashboardState`'s click hit-test both derive from it, keyed off `DetailTab.label`). Motivated by field notes: three low-density tabs forced needless cycling, and the tab bar was keyboard-only. Design proposal in `02_IMPLEMENTATION_PLANS/PROPOSALS/DashboardDetailTabErgonomics.md`. Tests: `DetailTab.allCases == [.summary, .checkers]`, clamped arrow switching, click-to-activate (incl. under scroll offset), tier picker on Summary, `DetailTabBar` geometry, and a tab-bar-line drift guard; existing four-tab tests updated to the two-tab model.
- **`deploy-local.sh` — stamp the build**: the CLI deploy path now regenerates the tracked `BuildStamp.swift` placeholder with the deployed commit + build time before `swift build`, then restores the placeholder on exit so the working tree stays clean. `quality-gate build-info` after a `deploy-local.sh` install now reflects the actual deployed commit instead of a stale one (`make build` already stamped; the script did not).
- **Result cache — invalidate on binary change (gate identity now reads the real executable)**: `gateIdentityHash` folds in the running executable's size+mtime so a rebuild/deploy invalidates every cached result — but the CLI passed `CommandLine.arguments.first`, which for a `PATH` invocation is the bare name `"quality-gate"` (a relative path `FileManager.attributesOfItem` can't stat). So the hash silently collapsed to its missing-file sentinel and **never changed when the binary was replaced**: after installing a new gate, index-backed checkers (`unreachable`, `complexity`, `recursion`, `concurrency`, `doc-coverage`) kept serving results computed by the *old* binary until the cache was cleared (observed live: a freshly-fixed `unreachable` checker still reported the pre-fix failure from cache; `--no-cache` recomputed and passed). New `CheckerFingerprint.runningExecutablePath()` resolves the real path via `Bundle.main.executablePath` (`_NSGetExecutablePath` / `/proc/self/exe`), falling back to `argv[0]`; the CLI now feeds that to `gateIdentityHash`. Verified: bare-name invocation resolves to the absolute install path, so size+mtime discriminate as designed. +5 tests (path resolves to an existing absolute file; identity differs by size, by toolchain, and from the missing-path sentinel).
- **ReleaseReadinessAuditor — accepts monorepo `Project@vX.Y.Z` tags**: `normalizeVersion` now strips a leading `Project@` scope prefix (everything up to and including the last `@`) before the existing `v`/`V` strip, so a tag like `IconquerApp@v0.1.0` normalizes to the bare `0.1.0` that `parseLatestChangelogVersion` already extracts from a `## [IconquerApp@v0.1.0]` heading. Previously repos using the `Project@v` tag convention could **never** pass `release-untagged-version` no matter how often they tagged — the tag normalized to itself and never equalled the bare changelog semver. Plain (`v1.2.0`) and bare (`1.0.0`) forms are unaffected; the change is strictly more permissive. +6 tests (prefixed-tag normalization, mixed-convention parity).
- **UnreachableCodeAuditor — skips the cross-module pass on a stale index (no more false positives from line drift)**: when the located index store is older than the newest source file, the reachability pass is now skipped (a `.note` points the user at a rebuild / `--auto-build-xcode`) instead of running against drifted line numbers and emitting `.error` findings. A stale index records each symbol at its *old* line; once source above it shifts — e.g. wrapping `import os` in `#if canImport(os)` adds two lines — every symbol below reports at the wrong line, so `// LIVE:` exemption matching misses and live symbols look dead. Real case: harbor flagged a `// LIVE:`-marked `Phase.discovery(progress:)` purely because its Xcode index predated an `import os` guard commit. Treating a stale store like a missing one keeps the gate from failing on data it can't trust; the syntactic pass still runs. New `shouldRunCrossModule(located:)` gate + a fresh-index regression test (real dead code and trailing-`// LIVE:` enum cases still handled correctly). +2 tests.
- **UnreachableCodeAuditor — honors `vendorPaths`**: files under `configuration.vendorPaths` are now excluded from **both** the syntactic and cross-module passes (folded into the effective exclude set alongside `excludePatterns`). Previously a project could declare a vendored third-party tree (e.g. `polar-ble-sdk`) as `vendorPaths`, yet the unreachable checker still scanned it and failed the gate on dead code the project doesn't own. The cross-module (index-backed) pass needed a second fix: its reachability loop iterates *every* indexed symbol, so emitted `unreachable.cross_module.*` diagnostics are now filtered by the exclude set at the return choke point (the file walk alone doesn't reach them). `SourceWalker.isExcluded(path:patterns:)` is exposed so both passes share one substring rule. +4 tests (syntactic: vendored dead code excluded, first-party still reported; cross-module: a vendored file's finding dropped while non-vendored findings remain; `isExcluded` matching). Verified end-to-end on a real workspace: 1064 vendored-SDK cross-module findings → 0.
- **TemporalDeterminismAuditor — bans wall-clock nondeterminism (new checker)**: the temporal analog of `StochasticDeterminismAuditor`. Motivated by a real portfolio regression: a simulation source (`SimulationDevice`) stamped every emitted sample with `ContinuousClock.now`, so under a `Task.sleep` loop the inter-sample spacing tracked scheduler jitter instead of the intended RR interval — making a downstream test flaky. Crucially the bug was in *production*, not the test, so the auditor scans both `Sources/` and `Tests/`. Two rules (both `warning`): `temporal-simulated-wall-clock` — a wall-clock read (`ContinuousClock.now`, `Date()`, `DispatchTime.now()`, `CFAbsoluteTimeGetCurrent()`, …) stamped as a timestamp value (a labeled arg like `timestamp:`/`at:`, or an assignment to a `*time*`/`*date*` property) **inside a simulation/synthetic/mock/fake/stub type** — scoped to simulated-source names so a real hardware device stamping `.now` is not flagged; and `temporal-wall-clock-assertion` — a test assertion (`#expect`/`#require`/`XCTAssertLessThan`-family) comparing *measured elapsed wall-clock time* (a clock delta, `.timeIntervalSince*`, `start.duration(to:)`, or a var bound to one) against a numeric threshold, which flakes under load. Escape hatches: per-line `// temporal:exempt` (both rules, recorded as a `DiagnosticOverride`), `// TIMING:` to mark an intentional wall-clock perf test, and config `exemptTypes`/`exemptFunctions`/`exemptFiles`. +15 tests (must-flag / must-not-flag for both rules, incl. the exact `SimulationDevice` and perf-benchmark shapes, plus exemptions). Design proposal in `02_IMPLEMENTATION_PLANS/PROPOSALS/TemporalDeterminismAuditor.md`.
- **`--no-index-build` — build-free index checkers for portfolio sweeps**: new flag (and `QG_NO_INDEX_BUILD` env) that forbids the gate from *compiling* a project to produce an index store. Index-backed checkers (`recursion`, `concurrency`, `unreachable`, `complexity`, `doc-coverage`) reuse an existing store (swiftbuild's `.build/out` or a prior index-build) when present, and otherwise **degrade to AST-only** analysis rather than triggering a build. Motivated by a real thrashing loop: a portfolio dashboard ran `quality-gate --check all` across ~100 projects every 2 hours, and because `--check all` includes index checkers (which need a compiled index), it cold-built every project whose `.build` had been deleted for disk space — refilling the drive and saturating the machine. With `--no-index-build`, a sweep runs fast and never compiles: proven end-to-end on an unbuilt package, `--check recursion --no-index-build` **passes in 0.23 s and creates no `.build/out`, no `index-build`, no compile artifacts**. `StoreLocator.ensureFresh` throws the new `Error.indexBuildSkipped` at the point a compile would be required; the checkers already catch an index-pass failure and fall back to their name-based/AST pass, so the flag needs no per-checker changes. +2 tests (throws-without-building when no store; still reuses a present store under the flag). The Xcode auto-build path remains separately gated by `--auto-build-xcode`.
- **Single-build index store — reuse swiftbuild's `.build/out` (kills the double-compile)**: `StoreLocator.ensureFresh` now reuses the index store that Swift 6.4+ SwiftPM (the `swiftbuild`/XCBuild default) index-while-builds to `.build/out/v5` during the *normal* build, instead of always running a separate `--build-system native` compile into `.build/index-build`. When that store exists and is current relative to `Sources`, the index checkers query it directly — **zero extra compile**. Previously every gate run that touched an index checker paid a full second build of the whole module graph (~230 s cold on this package); with local edits auto-rebuilt by the on-save hook, `.build/out` is already fresh at commit time, so the pre-commit gate no longer double-compiles. Proven end-to-end: with `.build/index-build` deleted, `--check recursion` completes without recreating it (uses `.build/out`), and `IndexStoreDB` opens `.build/out` and returns real symbols for first-party sources. Native toolchains (< 6.4, e.g. the 6.3.3 server) do **not** index without `-index-store-path` — confirmed by probe — so `.build/out` is absent there and the existing locked native index-build remains the fallback, unchanged. New `StoreLocator.freshSwiftbuildStore` (returns `.build/out` only when present, non-empty, and not stale); +4 fixture unit tests (absent/fresh/stale/empty) and +1 real-store queryability probe. This also retires the "double builds in CI" pressure that motivated the earlier `--build-system native` workaround.
- **Dashboard: middle-elide the Project/module column and group headers**: tight columns previously right-clipped names, so sibling modules collapsed to the same string (`BioFeedbackKitCore` / `UI` / `Tests` all shown as `BioFeedbackKit`) and a long group name could swallow its own ` (N)` member count. Project rows now elide via `ANSIStringMetrics.elideMiddle` (SwiftCLIKit **1.2.0**), preserving both the head and the identity-bearing camel-case suffix (`BioFeedba…Core`, `BioFeedback…UI`, `BioFeedb…Tests`); group headers elide **only** the name while always keeping the disclosure arrow and the ` (N)` count. Names that already fit are untouched — no gratuitous ellipses. Bumps the `SwiftCLIKit` dependency `from: 1.0.1` → `1.2.0`; +2 `TUIViewTests` (long name elides with arrow/count/suffix intact; short name unchanged).
- **Incremental result cache — all five index checkers opted in + config-salt safety fix (Lever 2, stage 3)**: the remaining cross-module index checkers — **`recursion`, `concurrency`, `unreachable`, `doc-coverage`** — now cache alongside `complexity`, each keyed by the whole source tree via `SourceCacheInputs.wholeSource`. The earlier "gated on memoizing per-file content hashes" caveat was **dropped**: measured, hashing the ~361 `Sources`/`Tests` files is ~1 s in a release binary against the ~50 s these checkers cost, so memoization buys nothing and adds a shared-mutable-state footgun — not worth it. **Safety fix (closes a latent silent-pass hole in the shipped `complexity` opt-in):** `wholeSource` now folds a digest of the *entire* `Configuration` (`JSONEncoder` with `.sortedKeys`, via new `CheckerFingerprint.digest(of:)`) into the cache salt, so **any** config change — a threshold, a feature flag, an exclude pattern — invalidates the cached result. Before this, a checker whose behavior depends on config (e.g. a complexity threshold) could serve a stale pass after the threshold tightened. Verified end-to-end: `recursion` run twice on unchanged source is a confirmed cache **hit** (entry mtime unmoved, analysis skipped); the residual warm-run time is the shared index-store refresh (Lever 1.5), amortized once across all five checkers in a real `--check all`. `SourceCacheInputs.wholeSource` signature changed to take `configuration:` (was `excludePatterns:`); test updated. A future lever could skip the index refresh entirely when every index checker is a cache hit — noted, not implemented.
- **Incremental result cache — activated (Lever 2, stage 2)**: the CLI now enables the cache (`--no-cache` disables it) and passes a gate-identity key — the executable's size+mtime plus the active toolchain version (`CheckerFingerprint.gateIdentityHash`) — so a gate rebuild or compiler change invalidates every entry. First checker opted in: **`complexity`**, whose cross-module result depends on the whole source tree; it caches keyed by all `Sources`/`Tests` `.swift` + `Package.swift`/`Package.resolved` via `SourceCacheInputs.wholeSource` — scoped to the project's source dirs, **not** `projectRoot` (which descends into `.build`'s 8,700+ dependency files and made the fingerprint ruinously slow; a dependency change is captured via `Package.resolved`). Verified end-to-end on the debug binary: an unchanged-source re-run is a cache **hit** that skips complexity's analysis (122 s → 57 s of which is debug-binary baseline), and `--no-cache` re-runs it. +1 regression test guarding the `.build`-exclusion. Opting in the other index checkers is a follow-up gated on memoizing per-file content hashes (otherwise each opted-in checker re-hashes the source tree).
- **Index-build lock (multi-session safety)**: `StoreLocator.ensureFresh` serializes concurrent index builds with an exclusive `flock(2)` advisory lock plus double-checked freshness — the first caller builds the store under the lock; concurrent callers (e.g. two `quality-gate` runs in one checkout) block, then re-evaluate and skip a redundant, racy rebuild once a peer produced the store. Without this, two `swift build` runs wrote the same store at once and a reader saw an empty/partial index (the intermittent cross-module-checker flake), which under load escalated to gate processes **deadlocking** (observed: four gates hung 1–47 min at 0% CPU during a concurrent dashboard session). Fast path (already-fresh) takes no lock. 2 new tests (re-acquire; 8-worker serialization proof, peak == 1). Git worktrees remain the general fix — see `Tools/HANDOFFS/multi-session-coordination.md`.
- **Incremental result cache — harness (gate speed, Lever 2, stage 1)**: infrastructure for skipping a checker when its inputs are unchanged, built on a strict safety property — a checker's result is a deterministic function of its inputs, so reusing a result only when the checker's *complete* input set is byte-identical can never produce a false pass. `CheckerFingerprint` computes a SHA-256 digest (via `swift-crypto`, chosen over CryptoKit for cross-platform/Linux capability) over the checker id, the gate binary hash, a salt (e.g. a config slice), and each input file's path + content hash (order-independent; a deleted file folds in an absent sentinel). `ResultCache` stores/loads `CheckResult`s on disk under `.build/quality-gate-cache/`, corruption-safe (a bad entry is a miss, a write failure never fails the gate). Pure infrastructure; 10 tests covering the digest-stability and corruption-safety guarantees. **Stage 2 plumbing** now also landed (still dormant): a `QualityChecker.cacheInputs(configuration:)` protocol hook (default `nil` = not cacheable, runs every time), and `CheckerRunner` cache integration behind a `useCache` flag (default off) that consults the cache only for opted-in checkers and stores the RAW result (so overrides are never baked in). 5 more tests prove the runner behavior: unchanged input → runs once (cache hit); changed input → re-runs; `cacheInputs == nil` → always runs; `useCache == false` → bypasses; a cached failure still surfaces as failing. **No checker opts in and the CLI does not enable `useCache`, so gate behavior is still unchanged.** Remaining (final, behavior-changing) step: CLI wiring (gate hash + `--no-cache`) and conservative per-checker opt-in (doc-lint, dependency-audit).
- **Shared index session (gate speed, Lever 1.5)**: the five index-dependent checkers (`complexity`, `recursion`, `concurrency`, `unreachable`-adjacent `doc-coverage`, `memory-lifecycle`) each independently opened the *same* index store — loading `libIndexStore.dylib`, building a temp `IndexStoreDB`, and polling every unit — so when Lever 1 ran them concurrently the redundant opens serialized, capping the full parallel-safe set at 1.8×. New `SharedIndexStore` (backed by a `KeyedAsyncCache` actor that deduplicates concurrent construction) opens each store **once** and shares the read-only `IndexStoreDB` (already `@unchecked Sendable`) across all checkers. Measured (release, quiet machine): parallel-safe wall **40.9 s → 20.5 s**, now **4.6× of a 5.35× ceiling** (~86% parallel efficiency, up from ~43%). Confirms concurrent *queries* on one `IndexStoreDB` do not meaningfully serialize — the redundant opens were the whole bottleneck. The 5 checker helpers became `async`; 3 new `KeyedAsyncCache` tests (incl. a 20-concurrent-→-1-construction dedup proof); all index-checker tests green.
- **Index-store production restored under Swift 6.4 (`swiftbuild` default)**: Swift 6.4's SwiftPM changed the default `--build-system` to `swiftbuild` (the integrated XCBuild engine), which does **not** honor `-Xswiftc -index-store-path` — it emits no queryable index store. This silently broke every cross-module index checker (`unreachable`, `complexity`, `recursion`, `concurrency`, `doc-coverage`): a freshly built fixture index had **0 units / 0 records**, so cross-module dead-code detection found no symbols (5 `UnreachableCodeAuditor` tests failed). Presented as "worked for a week, broke just now" because the previously cached index (built by the older `native` system) was only now regenerated. `StoreLocator.build` now forces `--build-system native` (108 units / 1982 records restored; `native` is deprecated — follow-up: adopt the swiftbuild index mechanism before removal). Separately, `IndexStoreSession.findLibIndexStore` now resolves `libIndexStore.dylib` from the **active** toolchain (`xcode-select`) instead of preferring a hardcoded `/Applications/Xcode.app` path (missing on Xcode-beta-only machines, where it fell back to a mismatched Command Line Tools library), and fixes a `usr/usr/lib` path bug in the `xcrun` fallback.
- **Parallel checker execution (gate speed, Lever 1)**: the CLI ran its ~28 checkers strictly sequentially, so wall-time was the sum of every checker (profiled: 106 s summed vs. a 28 s slowest single checker). New `CheckerRunner` (QualityGateCore) runs checkers in a bounded `withTaskGroup` (concurrency = active processor count) and returns results in checker order. Checkers are partitioned by a new `QualityChecker.isParallelSafe` property (default `true`): checkers that spawn `swift build`/`swift test` and lock the SwiftPM `.build` directory — `build`, `test`, `xcode-build` — plus `disk-clean` (which deletes `.build`) run **sequentially**, outside the group; the pure AST/file checkers run concurrently. This partition is required for correctness: naive parallelism contends on the `.build` lock and measured *slower* (492 s). Same checks, same diagnostics, same pass/fail — 10 new tests including concurrency and isolation proofs. `continueOnFailure` semantics preserved (a failing sequential checker skips the parallel phase; a failing parallel checker cancels the group). Measured (release binary): the 20 pure-AST checkers hit **2.2×** (19.0 s → 8.8 s, near the 2.5× ceiling set by the slowest single checker); the full parallel-safe set is **1.8×** (72.9 s → 40.9 s). The remaining headroom is the index-dependent checkers (`complexity`, `recursion`, `concurrency`, `unreachable`, `doc-coverage`) serializing on the shared `libIndexStore` — a follow-up (shared/concurrent index session) tracked separately.
- **ReleaseReadinessAuditor**: corrected the version/tag hygiene invariant. Two new rules — `release-untagged-version` (error): the latest *documented* CHANGELOG version must have a matching git tag; and `release-unresolvable-dependency` (error): every README-advertised `from:` / `.exact(` dependency version must resolve to an existing tag. Previously the auditor only checked whether the newest tag was *mentioned* in the CHANGELOG (a substring test, wrong direction), so a CHANGELOG racing ahead of its tags — the most common release-hygiene failure — went undetected. Adds pure, unit-tested functions (`parseLatestChangelogVersion`, `checkVersionTagParity`, `parseReadmeDependencyVersions`, `checkDependencyVersionsResolvable`) with 22 new tests, and two opt-out config flags (`checkVersionTagParity`, `checkDependencyResolvability`), both default-on. Uses the `[Unreleased]` convention: pending work sits here (skipped by the tag-parity check) and is promoted to a version heading when tagged.

## 2.0.1

- Dashboard TUI: removed the left/right vertical border edges (`│`) from every view (portfolio, project detail, group detail, pulse sections). Selecting and copying multi-line content — the weekly narrative especially — no longer drags box-drawing pipes into the clipboard, so narratives paste as clean shareable text. Visual ordering is preserved by full-width horizontal section rules and a titled top rule (`── IJS Portfolio Dashboard ──…`) instead of a four-sided box. Chrome logic centralized in `DashboardChrome` (`titleRule` / `sectionRule` / `contentRow`), collapsing four duplicated `boxRow` helpers into one.
- HIGAuditor context-menus rule: no longer false-positives on `List { ... }` views whose rows are delegated to extracted `@ViewBuilder` computed properties (a common SwiftUI pattern the AST visitor could not follow into) or on static Lists with no repeating items. The rule now fires only on Lists that actually produce rows — data-driven (`List(items) { ... }`) or containing a direct `ForEach` — matching its documented "List/ForEach items" intent. Genuine inline misses are still flagged.
- Checker selection: `disk-clean` (a destructive maintenance task that deletes `.build/` and runs `git gc`) is now opt-in — excluded from `--check all` unless explicitly named (`--check all --check disk-clean` or `--check disk-clean`). Previously `--check all` silently wiped the build cache and index store mid-gate, which made consecutive runs non-reproducible and spuriously errored index-store-dependent checkers. Selection logic extracted to `CheckerSelection` (QualityGateCore) with unit tests.
- Self-compliance: brought the tool's own source into compliance with the logging Rule 8 (`logging.unguarded-os-import`) added in 2.0.0 by wrapping every `import os` in `#if canImport(os) ... #endif` (62 files). The package targets macOS only, so this is a no-op at build time; it keeps the tool honest against its own checker. Also refreshed MASTER_PLAN test counts / auditor inventory to clear `status` drift.

## 2.0.0

- ComplexityAnalyzer Pass 2: cross-module cognitive complexity amplification via IndexStoreDB call graph resolution, 3x loop multiplier, cycle-safe visited set
- DocCoverageChecker Pass 2: inherited documentation detection from protocol requirements, usage-priority ranking by reference count, adjusted effective coverage reporting
- MemoryLifecycleGuard Pass 2: cross-file task cancellation, delegate retention detection, stream termination analysis, stale exemption cleanup
- DependencyAuditor: replaced all 6 NSRegularExpression patterns with SwiftSyntax AST parsing (ManifestParser + ImportVisitor); each manifest parsed once instead of 3x
- XcodeReporter: Xcode Build Phase integration with `--format xcode` output
- Configuration: DocCoverageConfig, MemoryLifecycleConfig.useIndexStore, ComplexityAnalyzerConfig cross-module fields
- CrossModuleCallEdge model, FunctionComplexityRecord amplified complexity fields, ComplexityBasis cross-module case
- All Pass 2 modules degrade gracefully when index store is unavailable
- 1662 tests across 211 suites, quality gate 0/0

## 1.2.0

- IndexStoreInfra shared module: ProjectKind, StoreLocator, IndexStoreSession, ConformanceQuery, SourceWalker
- RecursionAuditor Pass 2: USR-based call graph with iterative Tarjan SCC, cross-module and protocol witness cycle detection, syntactic base case scanning
- ConcurrencyAuditor Pass 2: cross-file Sendable stored property, isolation crossing, and preconcurrency import analysis (stub queries, pure analysis tested)
- AppIntentsAuditor: opt-in checker for App Intents readiness (entity conformance, parameter wrappers, metadata protocols)
- Configuration: RecursionAuditorConfig.useIndexStore, ConcurrencyAuditorConfig.useIndexStore/trackIsolationDepth
- Iterative Tarjan SCC algorithm handles 1000+ node graphs without stack overflow
- Pass 2 base case scanning reads cycle participant source for guard statements
- DocC articles for IndexStoreInfra and AppIntentsAuditor
- 5 design proposals for checker IndexStoreDB upgrade candidates
- 1556 tests across 205 suites, quality gate 0/0

## 1.1.0

- XcodeBuildChecker, HIGAuditor, ComplexityAnalyzer call-graph amplification
- Institutional Judgment System (IJS) with pulse, telemetry, and consistency scoring
- Anti-gaming mitigants: red-team dissent, conviction flags, minimum-deliberation windows
- IJSDashboardCore module with health timeline and portfolio rendering
- Hallucinated import detection in DependencyAuditor
- Master Plan tracking and status auditing

## 1.0.0

- 23 checkers across correctness, safety, security, documentation, accessibility, and project health
- 853 tests across 74 test files
- Zero-warning self-audit: all checkers pass clean against the quality-gate-swift codebase
- Comprehensive DocC catalogs for all 25 modules
- CLI with `--check all`, `--exclude`, `--strict`, `--continue-on-failure` flags
- JSON, SARIF, and terminal output formats
- `--fix` and `--dry-run` for auto-fixable checkers
- `--bootstrap` for generating initial status documents
- Severity override system: downgrade or upgrade any rule via `.quality-gate.yml`
- `--auto-build-xcode` for IndexStore generation in Xcode projects
- `QualityGateTestKit` module for writing checker tests
- Reusable GitHub Actions workflow for cross-repo adoption
- Security rule staleness workflow with automated issue creation
- Guide document covering vision, design philosophy, architecture, and integration patterns

<!-- generated:changelog-links -->
[Unreleased]: https://github.com/jpurnell/quality-gate-swift/compare/v3.1.0...HEAD
[3.1.0]: https://github.com/jpurnell/quality-gate-swift/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/jpurnell/quality-gate-swift/compare/v2.0.2...v3.0.0
[2.0.2]: https://github.com/jpurnell/quality-gate-swift/compare/v2026.07.12...v2.0.2
[2026.07.12]: https://github.com/jpurnell/quality-gate-swift/compare/v2026.07.10...v2026.07.12
[2026.07.10]: https://github.com/jpurnell/quality-gate-swift/compare/v2.0.1...v2026.07.10
<!-- /generated:changelog-links -->
