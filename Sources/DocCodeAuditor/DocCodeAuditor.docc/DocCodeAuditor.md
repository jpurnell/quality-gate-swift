# ``DocCodeAuditor``

Fenced Swift in documentation must compile.

## Overview

`doc-code` assembles every checked `swift` block in a DocC article into one program and
typechecks it against the built module. The compilation unit is the **article**: blocks are
concatenated in document order, so an article pastes into a playground and runs.

Two consequences follow, and both are the point rather than side effects:

- A later block that refers to an earlier binding is correct, and must keep working.
- Two independent examples that both open with `let data = …` are a defect in the article.
  The repair is a rename — `salesData`, `returnsData` — not an annotation. Prose that reuses
  a name for two different things confuses a reader too; the compiler is only the first to
  say so.

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
| `doc-code` | Does the code a reader would copy compile? | Prose, and code that compiles while being wrong |

## What it cannot tell you

Typechecking is a weaker guarantee than it looks. It does not catch a force-unwrapped `nil`,
an index out of range, or a documented result that is simply untrue — and under the
one-program convention it does not catch a reference that binds to the *wrong* object, since
both bindings typecheck and only meaning distinguishes them. A green verdict means the
article compiles, not that it is correct.

## Topics

### Checker

- ``DocCodeAuditor/DocCodeAuditor``

### Assembly and line mapping

- ``AssembledArticle``
- ``ArticleAssembler``

### Auditing one article

- ``ArticleAuditor``
- ``ArticleVerdict``
- ``DocCodeAuditOptions``

### Environment

- ``ArticleDiscovery``
- ``Catalogue``
- ``LanguageMode``
- ``ManifestLanguageMode``
- ``Toolchain``
