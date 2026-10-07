# Checking Pins Against Advisories

Read a finding, fix or acknowledge it, and keep the snapshot current.

## Overview

`dependency-advisory` runs in the default set and needs no setup: the gate ships with a snapshot of every published Swift advisory. This guide covers what a run prints, what to do about a finding, and how the snapshot stays fresh.

## Reading a run

```
$ quality-gate --check dependency-advisory dependency-advisory-freshness

✗ [dependency-advisory] FAILED
  error: swift-nio 2.86.0 is affected by GHSA-rj37-6j9x-74q6 (CVE-2026-28980, HIGH):
         SwiftNIO NIOHTTP1: HTTPDecoder accepts unbounded HTTP/1 header blocks, enabling
         remote DoS. Affected: < 2.100.0; fixed in 2.100.0. Pin: github.com/apple/swift-nio.
         Advisory data as of 2026-10-06. [CWE-1395]
     → Package.resolved:104
     fix: Update swift-nio to 2.100.0 or later: `swift package update swift-nio`
  note: dependency-advisory examined 1 lockfile · 23 pins · 23 third-party · 21 evaluable by
        version · 2 unevaluable · 1 affected by 3 advisories · 0 acknowledged · snapshot
        osv/SwiftURL fetched 2026-10-06 (64 records, 3 withdrawn, 32 packages; bundled)

✓ [dependency-advisory-freshness] PASSED
  note: The advisory snapshot (bundled) was fetched 2026-10-06, 0 days before 2026-10-06
        (maximum 14).
```

Every finding names the advisory, its CVE alias, its severity, the affected range, the fixed version, the pin, and **the date the advisory data is from**. The coverage note is the denominator: every number in it is a denominator for the one after it. A run that examined zero lockfiles, or a snapshot that names none of your packages, has said nothing — and the note is how you can tell.

## Fixing a finding

Most findings are one command:

```bash
swift package update swift-nio
```

An advisory with no fixed version cannot be cleared by upgrading. Replace the dependency, or acknowledge the advisory.

## Acknowledging an advisory that does not apply

`Package.resolved` is JSON; there is no line above it to carry a comment. The acknowledgement goes in `.quality-gate.yml`, and it has to say more than a comment would:

```yaml
dependencyAudit:
  acknowledgedAdvisories:
    - id: GHSA-g454-wj9r-jpg4
      package: github.com/marmelroy/Zip
      reason: "Transitive via polar-ble-sdk. No code path here extracts an archive."
      until: 2027-01-01
```

- **`id`** — the advisory's `GHSA-…` id or its `CVE-…` alias.
- **`package`** — the repository, in any spelling. Both `id` and `package` must match the finding.
- **`reason`** — why it does not apply. It is held to the gate's justification standard: at least eight words, and not a stock phrase such as "safe" or "not a problem".
- **`until`** — `YYYY-MM-DD`, required.

An accepted acknowledgement is recorded as an override and counted in the coverage note; it is never silent.

`until` is compared against **the snapshot's `fetched` date, not today's date**. An acknowledgement therefore expires when the gate's knowledge moves past it — on a snapshot refresh or a gate upgrade, which is also when a revised advisory would arrive — and the same tree with the same snapshot gives the same answer on any day. On expiry the finding returns, with `dep-advisory.acknowledgement-expired` beside it.

An acknowledgement that is not accepted leaves the finding in place and says why:

```
… [CWE-1395] (the acknowledgement in `dependencyAudit.acknowledgedAdvisories` was not
accepted: its reason has 3 words and 8 are required)
```

An acknowledgement that matches no finding is reported as `dep-advisory.acknowledgement-unused`. A stale exemption is how the next one gets copied.

## Keeping the snapshot current

A commit can be green and vulnerable for as long as the snapshot is stale. `dependency-advisory-freshness` reports the snapshot's age on every run, and reports it as stale past `advisorySnapshotMaxAgeDays`:

```
note: The advisory snapshot (bundled) was fetched 2026-09-06, 30 days before 2026-10-06; the
      maximum is 14. 23 pins in 1 lockfile were checked only against advisories known on
      2026-09-06 — nothing published since has been checked. Run `quality-gate advisories
      refresh`, or upgrade the gate for a newer bundled snapshot.
```

There are two ways to get a newer one:

- **Upgrade the gate.** Each release bundles a fresh snapshot.
- **Commit your own.** `quality-gate advisories refresh` downloads the current advisories and writes `.quality-gate/advisories/swifturl.json`. When both exist, the one fetched later is used and the coverage note names it.

```bash
quality-gate advisories refresh
git add .quality-gate/advisories/swifturl.json
```

The refresh prints which advisories arrived and which were withdrawn since the previous snapshot. It refuses to write a snapshot with fewer records than the one it replaces unless `--allow-shrink` is passed: advisories are withdrawn individually, not deleted, so a database that lost records is a failed download.

A committed snapshot makes the verdict a function of the tree alone. Relying on the bundled one makes it a function of the tree and the gate version — which means a gate upgrade can turn an unchanged commit red. That is the same event as the gate gaining a rule: the commit did not change, what is known about it did.

## Asking the live database

`dependency-advisory-drift` sends each pinned version to `https://api.osv.dev/v1/querybatch` and reports any advisory OSV returns that the snapshot does not hold:

```bash
quality-gate --check dependency-advisory-drift
```

It is opt-in, and by default it can only report notes. When OSV cannot be reached it is **skipped** — not passed, not failed — and says how much it did not check:

```
○ [dependency-advisory-drift] SKIPPED
  note: Skipped — external state unavailable: live OSV was not reached (The Internet
        connection appears to be offline.); 23 pins in 1 lockfile were not checked against
        the live database
```

A build does not fail because the network is down unless you ask for that with `--include-nonhermetic`, which lets both non-hermetic checkers gate. Set `dependencyAudit.offlineMode: true` to keep it off the network entirely; it then reports that it did not check, without attempting a connection.

Every request is bounded: at most 500 package versions per request and four requests per run, ten seconds and two megabytes each. Anything over the cap is counted in the note as not queried.

### CI

Run the hermetic check on every commit, and the live comparison on a schedule:

```yaml
steps:
  - name: Advisories
    run: quality-gate --check dependency-advisory --strict
```

```yaml
on:
  schedule:
    - cron: "0 6 * * 1"
steps:
  - name: Advisory drift and snapshot age
    run: quality-gate --check dependency-advisory-freshness dependency-advisory-drift --include-nonhermetic
```
