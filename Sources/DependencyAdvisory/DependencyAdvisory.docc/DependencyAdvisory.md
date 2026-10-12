# ``DependencyAdvisory``

Reports a pinned dependency version that a published security advisory says is vulnerable — without making the verdict depend on whether a server answered.

## Overview

An advisory is a dated fact. *"swift-nio before 2.100.0 accepts unbounded HTTP/1 header blocks"* was published on 2026-06-12 and will be true forever. Asking a server for it is non-hermetic; **having it** is not. So the lookup is split from the check:

- A **snapshot** holds the whole OSV `SwiftURL` export as of one day. The gate bundles one, and a repository may commit its own.
- `dependency-advisory` compares every `Package.resolved` in the tree against the snapshot. That is a pure function of the two files, so it works offline, gives the same answer on any day, and may fail a build.
- `quality-gate advisories refresh` is the only thing that downloads advisories, and the only thing that writes a snapshot.

What a snapshot cannot be is current, and two further checkers say so. Neither can fail a build unless `--include-nonhermetic` is passed, because neither finding is the commit's doing.

| Checker | Depends on | May fail the gate | Default set |
|---------|------------|-------------------|-------------|
| `dependency-advisory` | the lockfiles and the snapshot | yes | yes |
| `dependency-advisory-freshness` | the snapshot's date and the clock | only under `--include-nonhermetic` | yes |
| `dependency-advisory-drift` | live OSV | only under `--include-nonhermetic` | no — `--check dependency-advisory-drift` |

Three ids for one subject, because a checker declares one hermeticity and these are three different dependencies.

### Detected rules

| Rule ID | What it reports | Severity |
|---------|-----------------|----------|
| `dep-advisory.vulnerable-pin` | A pinned version inside a range an advisory says is affected | error for CRITICAL and HIGH; warning for MODERATE, LOW and unlabelled |
| `dep-advisory.vulnerable-pin-by-name` | The same, where the advisory names the package without a URL | as above |
| `dep-advisory.unevaluable` | An advisory names the package, and the pin or the range cannot be compared | warning |
| `dep-advisory.no-snapshot` | Third-party pins present and no usable snapshot | warning |
| `dep-advisory.snapshot-corrupt` | A snapshot that is not what its header says it is | error |
| `dep-advisory.acknowledgement-expired` | An acknowledgement whose `until` the snapshot's date has reached | warning |
| `dep-advisory.acknowledgement-unused` | An acknowledgement that matches no finding | warning |
| `dep-advisory.coverage` | What was examined, and against which snapshot | note |
| `dep-advisory.snapshot-stale` | Snapshot older than the maximum age (`dependency-advisory-freshness`) | note; error under `--include-nonhermetic` |
| `dep-advisory.snapshot-age` | The snapshot's age, when within the maximum | note |
| `dep-advisory.unlisted` | Live OSV names an advisory the snapshot lacks (`dependency-advisory-drift`) | note; error under `--include-nonhermetic` |
| `dep-advisory.drift-coverage` | What the live comparison asked, and what it did not | note |

MODERATE is a warning on arrival and an error at its destination; CRITICAL and HIGH are errors from the first day. Severity is GitHub's label on the record, not a score recomputed from the CVSS vector.

### What it reads

Every `Package.resolved` under the project root: the package's own, nested packages', and Xcode's workspace copy under `*.xcworkspace/xcshareddata/swiftpm/`. Build output, checkouts, `DerivedData` and `.claude` worktree copies are skipped. Lockfile format versions 1, 2 and 3 are read.

### How it matches

Matching is local, because the live API gives wrong answers in ways that matter:

- **Case.** OSV matches package names case-sensitively. `github.com/marmelroy/zip` returns nothing; `github.com/marmelroy/Zip` returns an advisory. A lockfile records whatever the manifest typed, so names are compared case-insensitively.
- **Records that name no URL.** Three records in the export give a bare name — `swift-nio-http2`, `swift-crypto`, `CocoaMQTT` — and the API, queried by URL, never returns them. A bare name is matched to the pin's last path component and reported as `vulnerable-pin-by-name`, with both spellings in the message.
- **Versions.** A two-component bound such as `1.20` is padded, not failed open. A bound that is not a version makes the range `unevaluable` — never a hit and never clean.
- **Moved packages.** `apple/swift-syntax` and `swiftlang/swift-syntax` are the same package, for a listed set of packages that moved.

A branch or bare-revision pin has no version to compare. If any advisory names the package, that is `unevaluable`; if none does, the pin is counted and silent.

### What it cannot see

- **Whether the vulnerable code is reached.** A CLI that links `swift-nio` for an HTTP client never runs the HTTP server's decoder. The rule reports the pin.
- **A vulnerability nobody has reported.** The export was 64 records for the whole ecosystem on 2026-10-06. Most pinned packages have no record at all; they are not known to be safe, they are not known.
- **Anything not in a lockfile** — `path:` dependencies, vendored source, binary targets, the toolchain.
- **What a consumer of a library will resolve.** A library's own lockfile constrains nothing downstream.

## Configuration

The advisory checkers share the `dependencyAudit` block with `dependency-audit`.

```yaml
dependencyAudit:
  acknowledgedAdvisories:
    - id: GHSA-g454-wj9r-jpg4
      package: github.com/marmelroy/Zip
      reason: "Transitive via polar-ble-sdk. No code path here extracts an archive."
      until: 2027-01-01
  advisorySnapshotPath: .quality-gate/advisories/swifturl.json
  advisorySnapshotMaxAgeDays: 14
  ownPackages:
    - github.com/your-org/
  offlineMode: false
```

- **`acknowledgedAdvisories`** (default: `[]`) — Advisories this repository has decided do not apply. See <doc:DependencyAdvisoryGuide>.
- **`advisorySnapshotPath`** (default: `.quality-gate/advisories/swifturl.json`) — Where a repository commits its own snapshot. Optional; when it and the bundled snapshot both exist, the one fetched later is used.
- **`advisorySnapshotMaxAgeDays`** (default: `14`) — How old the snapshot may be before `dependency-advisory-freshness` reports it as stale.
- **`ownPackages`** (default: `[]`) — Repository-URL prefixes that are your own packages. They are still matched against advisories; the list decides what the coverage note counts as third-party.
- **`offlineMode`** (default: `false`) — When true, `dependency-advisory-drift` does not attempt a connection and reports that it did not check.

## Topics

### Checkers

- ``DependencyAdvisoryChecker``
- ``AdvisoryFreshnessChecker``
- ``AdvisoryDriftChecker``

### Refreshing the snapshot

- ``AdvisoryRefresh``
- ``AdvisoryRefreshError``

### Guides

- <doc:DependencyAdvisoryGuide>
