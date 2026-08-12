# ``DocGeneratedAuditor``

Derived content committed as prose must still match what it was derived from.

## Overview

A region hands the bytes between two delimiters to a named generator:

```
<!-- generated:error-registry -->
| Case | Meaning |
| --- | --- |
<!-- /generated:error-registry -->
```

Everything between the delimiters is the generator's; everything outside is the author's.
The checker regenerates each region in memory and compares. It never writes.

## Why a delimited region and not a marked line

This package already ships a generator. `MemoryBuilder` marks its output two ways: a
whole-file `generated-by:` front-matter tag, and a `<!-- generated -->` suffix on a single
index line. The suffix form **cannot express deletion**. A line that was generated and then
lost its marker — through a hand edit, a merge, or a generator whose output shape changed —
becomes immortal, because nothing can distinguish it from a line a human wrote. The live
index this project loads at session start carries five duplicated pairs for exactly that
reason, one entry claiming 72 targets beside a generated one claiming 116, both loaded.

A region fixes this by construction: deletion is just "the new region has fewer lines". A
marked line is a degenerate one-line region and a whole-file tag is a degenerate whole-file
region, so the region is the general case and the other two are special cases of it.

## Regions wrap rosters, not judgments

A tick-box means *this is done*, which is a judgment no generator can make; deriving it from
"a directory exists" would make a checklist assert something it cannot know. But *which
things deserve a line* is a set a tool can compute exactly.

So a roster region owns membership and nothing else. It adds lines and removes lines; it
never flips a tick-box and never rewrites a description. `status` owns that column and
already updates it. Two readers of one file is not a defect; two writers of the same bytes
is, and these two do not overlap.

## Nothing a document declares may decide its own verdict

Generators are compiled in, one conformance per id. There is no configured command, in any
phase, on two independent grounds.

`GatePlugins` does execute configured executables, and it is safe because a plugin finding
is downgraded to a note unless the entry declares `gates: true` — the safety of running a
declared command is purchased by making its verdict non-binding. This rule gates, so it
cannot make that purchase.

Second, and surviving even if the first does not move you: whoever can write a stale region
can also write the command beside it that reproduces the stale region. A reference supplied
by the thing under test verifies nothing. Making the derivation a property of the tool is
what turns changing it into a code review.

The cost is stated rather than hidden: a repository whose derived content depends on the
runtime behaviour of its own library gets nothing here, and is told so rather than passing.

## Coverage is reported, not assumed

Every run prints regions found, regenerated, unknown, and generators left unused — pass or
fail, including when the answer is zero. A gate that under-reports its own coverage is
indistinguishable from a gate that passes. An unknown id is an error and never a skip: a
misspelled region that scanned clean and checked nothing would read as governed while being
governed by nothing.

## Topics

### The checker

- ``DocGeneratedAuditor/DocGeneratedAuditor``

### Regions

- ``RegionScanner``
- ``GeneratedRegion``
- ``RegionDefect``
- ``RegionScan``

### Scope

- ``GovernedDocuments``
- ``GovernedDocument``

### Generators

- ``RegionGenerator``
- ``RegionGeneratorRegistry``
- ``RegionGeneratorError``
- ``ChangelogLinksGenerator``
- ``ErrorRegistryGenerator``
- ``ModuleStructureGenerator``
- ``StatusRosterGenerator``

### Rosters

- ``Roster``
- ``PackageTargets``

### Comparison

- ``RegionDiff``

### Self-contradiction

- ``SelfContradictionRule``
- ``SelfContradiction``
- ``ChecklistParser``
- ``ChecklistItem``
