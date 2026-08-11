# ``DocCodeAuditor``

Fenced Swift in documentation must compile.

## Overview

This module ships **two** checkers over one set of machinery. They differ in exactly one
thing — where the fence lives — and that difference decides everything else about them.

| Checker | Corpus | Compilation unit |
| --- | --- | --- |
| `doc-code` | `.docc` articles | The **article**, blocks concatenated |
| `doc-comment-code` | `///` and `/** */` doc comments in `Sources/` | The **fence**, on its own |

`doc-code` assembles every checked `swift` block in a DocC article into one program and
typechecks it against the built module. The compilation unit is the **article**: blocks are
concatenated in document order, so an article pastes into a playground and runs.

Two consequences follow, and both are the point rather than side effects:

- A later block that refers to an earlier binding is correct, and must keep working.
- Two independent examples that both open with `let data = …` are a defect in the article.
  The repair is a rename — `salesData`, `returnsData` — not an annotation. Prose that reuses
  a name for two different things confuses a reader too; the compiler is only the first to
  say so.

## `doc-comment-code`, and why it is upstream

`doc-comment-code` compiles the doc comments the catalogue was copied *from*. The
distinction is not theoretical: the commit that repaired 26 articles in this package found
real API drift doing it — a `Configuration.default` that no longer existed, a `limitToFiles`
that had been retyped — and touched no doc comment at all. The article that shows
`MyChecker` was forced to declare its helper and import `QualityGateCore`; the `///` comment
on `QualityChecker` itself, four directories away, still carries the abbreviated version, and
Quick Help still serves it. **The catalogue checker repaired the copy and could not see the
original.**

Three things follow, and each one is a decision rather than an implementation detail:

- **The unit is one fence.** Not the doc comment: `HIGAuditor` carries a single `///` run
  holding a usage example *and* a fragment of the reader's own SwiftUI, separated by a
  heading. They share a comment and nothing else. Concatenating them would import the
  article rule into a place where its premise — *one program, pasted end to end* — is false.
  Nobody pastes a Quick Help panel. So there is no collision detection here, and a name
  declared in two fences of one comment is not a defect.
- **The preamble is `Foundation` plus the owning module, and nothing widens it** — not the
  module's dependency closure, not `extraImports`. Measured: injecting the closure would
  have turned ten of sixteen failures green while the examples stayed uncopyable, because the
  missing `import` *is* the defect a reader hits. Whatever a fence needs in order to compile
  is exactly what someone copying it has to type.
- **Only `swift`-tagged fences are compiled.** Untagged and foreign-tagged fences are never
  guessed at, and are counted in the coverage line so the silence is legible.

Extraction is SwiftSyntax trivia rather than a line scan, and the cost of the alternative is
exactly one fence: a regex reports 21 Swift doc fences in this package where the strict count
is 20, and the twenty-first is an inline code span in prose — in the sentence just below,
which explains why the opt-out is an HTML comment.

## The one opt-out

```
<!-- docs:illustrative -->
```

Placed before a fence, it skips that block — a bare signature, pseudo-code, a deliberate
counter-example, or a quoted excerpt of a type the module already defines. Exemptions are
**counted and reported per article**, never applied automatically. A gate that reaches for
its own opt-out is silencing the check rather than satisfying it.

## Coverage is reported, not assumed

Every article reports fences *found* separately from fences *checked*. This is not
bookkeeping. An earlier version matched fences at column zero, so blocks indented inside
list items were silently skipped — six articles passed with unchecked code in them, and that
code held real API drift, because troubleshooting steps and "try this instead" fragments are
the least-reviewed content in any guide. A gate that under-reports its own coverage reads
exactly like a gate that passes.

## Relationship to the other documentation checkers

Complementary, not overlapping. Merging any two of them loses whatever the other saw:

| Checker | Asks | Blind to |
| --- | --- | --- |
| `doc-lint` | Does DocC build the catalogue without diagnostics? | Anything inside a fence |
| `doc-coverage` | Does public API carry a doc comment? | What the comment says |
| `doc-code` | Does the code a reader would copy *out of an article* compile? | Prose, and code that compiles while being wrong |
| `doc-comment-code` | Does the code a reader would copy *out of Quick Help* compile? | The same, plus everything outside a fence — which is most of what Quick Help shows |

## What it cannot tell you

Typechecking is a weaker guarantee than it looks. It does not catch a force-unwrapped `nil`,
an index out of range, or a documented result that is simply untrue — and under the
one-program convention it does not catch a reference that binds to the *wrong* object, since
both bindings typecheck and only meaning distinguishes them. A green verdict means the
article compiles, not that it is correct.

## Topics

### Checkers

- ``DocCodeAuditor/DocCodeAuditor``
- ``DocCommentCodeAuditor``

### Assembly and line mapping

- ``AssembledArticle``
- ``ArticleAssembler``

### Auditing one article

- ``ArticleAuditor``
- ``ArticleVerdict``
- ``DocCodeAuditOptions``

### Auditing one doc-comment fence

- ``DocCommentFenceExtractor``
- ``DocCommentFence``
- ``DocCommentCensus``
- ``DocCommentFenceAuditor``
- ``DocCommentFenceVerdict``

### Environment

- ``ArticleDiscovery``
- ``Catalogue``
- ``LanguageMode``
- ``ManifestLanguageMode``
- ``Toolchain``
