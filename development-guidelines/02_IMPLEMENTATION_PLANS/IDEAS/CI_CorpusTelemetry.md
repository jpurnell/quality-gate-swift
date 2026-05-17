# Design Proposal: CI Corpus Telemetry

**Date:** 2026-05-16
**Status:** Idea
**Author:** Claude (AI Assistant)

---

## Objective

Emit IJS corpus telemetry from GitHub Actions CI runs to a dedicated repository branch, enabling multi-environment trend analysis (local vs. CI) and contributor-independent data accumulation.

**Master Plan Reference:** IJS Pulse architecture — extends the existing local corpus with a CI-sourced data stream.

---

## Problem Statement

Currently, corpus telemetry is emitted only during local `quality-gate` runs. This works well for a single maintainer but has limitations:

1. **Data gaps** — if you skip a local run, no telemetry is recorded for that commit
2. **Environment bias** — local runs may differ from CI (different Swift version, OS, Xcode)
3. **Multi-contributor** — if others contribute, their local runs don't feed the shared corpus
4. **Auditability** — CI telemetry provides a tamper-resistant record (tied to specific commits)

---

## Proposed Architecture

### Data Flow

```
PR merged to main
    -> CI builds quality-gate
    -> Runs complexity + consistency checkers
    -> Writes telemetry JSON to /tmp/corpus
    -> Clones corpus repo, commits, pushes
```

### Target Repository

A dedicated repo (e.g., `jpurnell/ijs-corpus`) with a branch per source project:
- `quality-gate-swift/` — telemetry from this project
- `narbis-app/` — telemetry from narbis (if adopted)

### Workflow Addition (quality-gate.yml)

```yaml
- name: Emit corpus telemetry
  if: github.event_name == 'push' && github.ref == 'refs/heads/main'
  env:
    CORPUS_TOKEN: ${{ secrets.CORPUS_PAT }}
  run: |
    git clone --depth 1 https://x-access-token:${CORPUS_TOKEN}@github.com/jpurnell/ijs-corpus.git /tmp/corpus
    export QG_CORPUS_PATH=/tmp/corpus/quality-gate-swift
    mkdir -p "$QG_CORPUS_PATH"
    .build/release/quality-gate --check complexity --check consistency \
      --config .quality-gate.yml --continue-on-failure
    cd /tmp/corpus
    git add .
    git diff --cached --quiet || git commit -m "ci: telemetry $(git -C $GITHUB_WORKSPACE rev-parse --short HEAD)"
    git push
```

### Configuration

Add a CI-specific corpus path via environment variable override:
```yaml
# .quality-gate.yml
consistency:
  corpusPath: "${QG_CORPUS_PATH:-~/.ijs-corpus}"
```

Or simpler: detect `CI=true` in `TelemetryWriter` and use `QG_CORPUS_PATH` env var.

---

## Concurrency Handling

Multiple PRs merged in quick succession could race on the corpus repo push. Options:

1. **Retry with rebase** — if push fails, pull --rebase and retry (1-2 attempts)
2. **Unique branches** — push to `telemetry/<sha>` then merge via PR (over-engineered)
3. **Accept occasional skip** — if push fails, log warning but don't fail the CI job

Option 1 is simplest and sufficient for low-frequency pushes.

---

## Security Considerations

- Fine-grained PAT scoped to only `contents: write` on the corpus repo
- Token stored as repository secret, never logged
- Corpus repo is append-only data (JSON files) — no executable content
- CI job only runs on push to main (not on PRs from forks)

---

## Effort Estimate

| Component | Effort |
|-----------|--------|
| Create corpus repo | 5 min |
| Generate fine-grained PAT | 5 min |
| Add workflow step | 15 min |
| Add env var support to config/writer | 30 min |
| Test end-to-end | 30 min |
| **Total** | ~1.5 hours |

---

## Effort Drift Over Time

**The effort does not increase by waiting.** The implementation is isolated workflow YAML plus a small config enhancement. The corpus data models (`ComplexityReport`, `CheckResultMetadata`, telemetry JSON format) are stable. No migration or backfill is needed — CI telemetry starts accumulating from the first run forward. Local corpus data remains valid independently.

If anything, waiting slightly benefits stability: more confidence that the data format won't need breaking changes.

---

## When to Implement

Good triggers:
- A second contributor starts working on the project
- You want CI-vs-local drift detection in Pulse reports
- You want an audit trail of complexity trends tied to specific commits
- You start consuming quality-gate in multiple projects and want unified telemetry

Not urgent because: single-maintainer local runs already capture complete telemetry.

---

## Alternatives Considered

| Alternative | Tradeoff |
|-------------|----------|
| GitHub Actions artifacts | 90-day retention limit, not queryable as a corpus |
| Git notes on main | Clever but fragile, hard to query across time windows |
| External DB (SQLite in repo) | Merge conflicts on binary file |
| Cloud storage (S3/GCS) | Additional infra, cost, auth complexity |

Dedicated repo with JSON files is the simplest option that preserves the existing corpus reader/writer unchanged.
