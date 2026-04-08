# UnreachableCodeAuditor v9 — more domains

**Status:** PARKED · evaluate each as a standalone proposal when needed
**Estimated cost:** 1-3 sessions per domain
**Common theme:** each domain is a new bug class, not an iteration of
the existing one. Build them in response to a real project asking for
the coverage.

---

## Domain 1 — Dead types

**What it catches:** A `class` / `struct` / `enum` declared, never
instantiated, never extended, never conformed-to.

**Why it's hard:** Type usage is implicit. A type can be "used" by:
- being instantiated (`MyType()`)
- being passed as a metatype (`MyType.self`)
- being mentioned in a protocol conformance (`extension MyType: Foo`)
- being mentioned in a generic constraint (`func f<T: MyType>()` —
  rare for classes, common for protocols)
- being mentioned in a `KeyPath` (`\MyType.foo`)
- being subclassed
- being referenced in a `@objc` runtime lookup (`NSClassFromString`)

The auditor today tracks type *member* references but not type
*identity* references. To do this right we'd need a separate "type
reference" pass over the index.

**Effort:** 2-3 sessions. Risk: medium-high — `KeyPath` and `.self`
references are easy to miss and produce false positives.

**Status:** PARKED. Build only when a user reports "I have an unused
class but the auditor doesn't tell me."

---

## Domain 2 — Dead `case` via switch exhaustiveness

**What it catches:** Enum cases that are never matched in any switch
statement and never instantiated. Today v3+ catches the "never
referenced" cases via the same path as functions (and v3 added
fixture coverage). What's *not* covered: cases that are matched only
inside an `@unknown default:` arm — i.e. they're "matched by exclusion"
but never explicitly named.

**Why it's hard:** swiftc already warns about non-exhaustive switches.
Replicating that logic is duplicative; the value is in the cross-file
"this case is never explicitly handled anywhere in the codebase" angle.

**Effort:** 1 session.

**Status:** PARKED. The motivating real-world finding hasn't shown up
yet on the codebases we've tested. Build when it does.

---

## Domain 3 — Conditional compilation (`#if`) coverage

**What it catches:** Code under an `#if PLATFORM_X` that's never the
active platform for any build configuration. SwiftParser parses every
branch by default (with `viewMode: .sourceAccurate`), so today the
auditor sees code that wouldn't compile and may emit confusing
findings.

**Why it's hard:** "Active platform" depends on build configuration,
which we'd need to read from `Package.swift` / `pbxproj` / xcconfig.
The right answer is to audit *each configuration separately* and merge
the findings (a symbol is dead only if it's dead in every
configuration).

**Effort:** 2-3 sessions. Risk: high — this is essentially writing a
configuration matrix runner.

**Status:** PARKED indefinitely. The current behavior (parse all
branches as if active) gives more findings than fewer, which is the
safe direction. Revisit if a real project produces conflicting
findings between debug and release.

---

## Domain 4 — Generated-code skip patterns

**What it catches:** *Suppresses* findings inside known generated
files (sourcery output, swiftgen, GraphQL codegen, Apollo's
`API.swift`, protobuf, etc.). The auditor today already honors
`excludePatterns` from `.quality-gate.yml`, so this is mostly
documentation + sensible defaults rather than new code.

**Effort:** 1 session.

**Approach:** add a `defaultGeneratedPatterns` set to `SourceWalker`
that's applied automatically unless overridden:

```swift
static let defaultGeneratedPatterns: Set<String> = [
    "*+Generated.swift",
    "*.generated.swift",
    "**/Generated/**",
    "**/Sourcery/**",
    "**/Apollo/**/*.swift",
]
```

And document the override in README.

**Status:** READY but trivial. Bundle into v6 maintenance work or do
when someone hits it.

---

## Domain 5 — Workspace with multiple top-level packages

**What it catches:** `.xcworkspace` files that contain multiple
sibling SwiftPM packages or xcodeproj projects. Today v5's
`.xcworkspace` detection is shallow — it locates the workspace's own
DerivedData entry but doesn't enumerate sub-projects.

**Why it might matter:** large codebases organize as multi-package
workspaces. The auditor would only audit the workspace's top-level
sources, missing dead code in sub-packages.

**Effort:** 2 sessions. Need to parse the workspace's
`contents.xcworkspacedata` XML, enumerate FileRef entries, and audit
each as a sub-project.

**Status:** PARKED. Wait for a real multi-package workspace to test
against; the design is straightforward but premature without an
example.

---

## Decision criterion for any of these

Each of the five is real but speculative. The right time to build any
one of them is:

1. A project lands that has the bug class
2. The current auditor misses it
3. A workaround (e.g. `excludePatterns`) isn't enough

Don't build proactively. The cost of carrying unused features is real
(maintenance, configuration surface, false positives in unrelated
codebases). The cost of *not* having them when needed is one session
of work — cheap.

---

## What to do instead

The most useful v9-era work is probably **not** here at all. It's:

1. **Run the auditor on more codebases.** Each new codebase reveals
   either (a) a real bug class missing, which becomes the actual v9,
   or (b) a false-positive class to add to the allow-list.
2. **Document the findings format.** SARIF output exists; the
   terminal output works; nothing in between (e.g. a Markdown report
   for code review). Could be a 1-session win.
3. **IDE integration.** A SourceKit-LSP plugin or VSCode extension
   that surfaces findings inline. Big effort, big payoff for adoption.

When you come back to this folder, read these three notes *before*
picking from the v9 list above.
