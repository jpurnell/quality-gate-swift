# Design Proposal: CI-Native Telemetry Push

## 1. Objective

**Objective:** Make CI the primary, zero-friction path for pushing quality gate telemetry into the institutional judgment corpus, so that every quality gate run on every repo automatically participates in the organizational feedback loop.

**Master Plan Reference:** IJS absorption (InstitutionalJudgmentSystem proposal, Section 14 "Future Directions" -- "CI-native telemetry push"). Depends on the IJS absorption being complete and the `quality-gate telemetry-push` subcommand existing in the CLI.

## 2. Motivation

**Current situation:** The IJS telemetry pipeline requires manual invocation of `ijs-telemetry push --gate-results results.json --config .quality-gate.yml` after every quality gate run. The existing `Push.swift` command in `org-judgement-system` builds `CheckResultMetadata`, runs consistency scoring, writes telemetry, and refreshes daily snapshots -- but only if someone remembers to run it. No one does.

**Workaround:** Developers would need to: (1) run quality-gate with `--format json`, (2) pipe the output to a file, (3) manually invoke `telemetry-push` with the correct corpus path and project ID, (4) commit and push the corpus changes. This four-step process is entirely manual and has never been performed in practice.

**Drawback:** The institutional feedback loop (Sensor -> Aggregator -> Refiner -> PolicyDiscovery) never fires. Override decisions, consistency scores, trend analysis, and the Institutional Pulse all remain empty. The IJS is dead weight without automated telemetry ingestion.

## 3. Proposed Architecture

### Overview

The telemetry push is integrated directly into the existing reusable workflow (`quality-gate-reusable.yml`). After the quality gate run completes, additional steps checkout the corpus repo, invoke the absorbed `quality-gate telemetry-push` subcommand, and commit/push corpus changes. The entire flow is opt-in: callers provide `corpus-repo` and `corpus-token` inputs to enable it.

### New Files

```
.github/workflows/quality-gate-reusable.yml  (modified -- add telemetry steps)
docs/ci-telemetry-setup.md                    (setup guide for adopters, only if requested)
```

### Modified Files

```
.github/workflows/quality-gate-reusable.yml
  - Add workflow_call inputs: corpus-repo, corpus-token, telemetry-enabled
  - Add post-gate steps: checkout corpus, run telemetry-push, commit & push
  - Add concurrency group to serialize corpus writes per project
```

### No New Swift Code

This proposal is pure CI infrastructure. The Swift-side `telemetry-push` subcommand is delivered by the IJS absorption proposal. This proposal consumes that command from within GitHub Actions.

### Workflow Architecture

```
quality-gate-reusable.yml
  |
  +-- [existing] Checkout project
  +-- [existing] Setup Xcode
  +-- [existing] Build quality-gate from latest main
  +-- [existing] Run quality gate
  |       |
  |       +-- outputs: results.json (--format json)
  |
  +-- [NEW] Checkout corpus repo (conditional on telemetry-enabled)
  +-- [NEW] Run telemetry-push
  +-- [NEW] Commit & push corpus (with retry on conflict)
```

### Concurrency Model

GitHub Actions' `concurrency` key serializes jobs that would write to the same corpus. Each consuming project gets its own concurrency group (`telemetry-${{ inputs.corpus-repo }}`), ensuring that concurrent pushes from different branches of the same project do not collide. Cross-project concurrency (different repos pushing to the same corpus) is handled by git rebase-and-retry within the push step.

## 4. API Surface

The "API" here is the reusable workflow's input contract.

```yaml
# Proposed additions to workflow_call inputs
inputs:
  # ... existing inputs (checks, continue-on-failure, config) ...

  telemetry-enabled:
    description: "Push telemetry to corpus after quality gate run"
    type: boolean
    required: false
    default: false

  corpus-repo:
    description: "GitHub repository for the IJS corpus (e.g., org/judgement-corpus)"
    type: string
    required: false
    default: ""

  corpus-branch:
    description: "Branch in the corpus repo to push telemetry to"
    type: string
    required: false
    default: "main"

secrets:
  corpus-token:
    description: "PAT or deploy key with push access to corpus repo"
    required: false
```

### Consumer Usage

```yaml
# In consuming project's CI workflow
jobs:
  quality-gate:
    uses: jpurnell/quality-gate-swift/.github/workflows/quality-gate-reusable.yml@main
    with:
      telemetry-enabled: true
      corpus-repo: jpurnell/org-judgement-corpus
    secrets:
      corpus-token: ${{ secrets.CORPUS_PUSH_TOKEN }}
```

### Telemetry Push Step (Implementation Detail)

```yaml
- name: Checkout corpus
  if: inputs.telemetry-enabled && inputs.corpus-repo != ''
  uses: actions/checkout@v4
  with:
    repository: ${{ inputs.corpus-repo }}
    ref: ${{ inputs.corpus-branch }}
    token: ${{ secrets.corpus-token }}
    path: _corpus

- name: Push telemetry to corpus
  if: inputs.telemetry-enabled && inputs.corpus-repo != ''
  env:
    CORPUS_PATH: _corpus
    PROJECT_ID: ${{ github.repository }}
  run: |
    # Run telemetry-push using the JSON output from the gate step
    quality-gate telemetry-push \
      --corpus-path "$CORPUS_PATH" \
      --project-id "$PROJECT_ID" \
      --input results.json

    # Commit and push corpus changes with retry on conflict
    cd "$CORPUS_PATH"
    git config user.name "quality-gate[bot]"
    git config user.email "quality-gate[bot]@users.noreply.github.com"
    git add -A

    if git diff --cached --quiet; then
      echo "No telemetry changes to commit."
      exit 0
    fi

    COMMIT_MSG="telemetry: ${{ github.repository }}@${{ github.sha }}"

    # Retry loop: rebase and push, handling concurrent writers
    MAX_RETRIES=3
    for attempt in $(seq 1 $MAX_RETRIES); do
      git commit -m "$COMMIT_MSG" || true
      if git push origin ${{ inputs.corpus-branch }}; then
        echo "Telemetry pushed successfully (attempt $attempt)."
        exit 0
      fi
      echo "Push conflict (attempt $attempt/$MAX_RETRIES), rebasing..."
      git pull --rebase origin ${{ inputs.corpus-branch }}
    done

    echo "::warning::Telemetry push failed after $MAX_RETRIES attempts. Corpus may be under heavy contention."
    exit 0  # Non-fatal: telemetry failure should not fail the quality gate
```

## 5. MCP Schema

N/A -- this is CI infrastructure (GitHub Actions workflow steps), not an MCP tool. The quality gate CLI's `telemetry-push` subcommand is a local CLI, not an MCP endpoint. If corpus queries are later exposed as MCP tools, schemas would be defined in a separate proposal.

## 6. Constraints & Compliance

**Concurrency:** The workflow uses GitHub Actions' `concurrency` key to serialize corpus writes per project. The rebase-and-retry loop handles cross-project contention. No Swift concurrency concerns -- this is shell scripting.

**Credential Isolation:** The `corpus-token` secret is scoped to the telemetry push steps only. It is never exposed to the quality gate build or run steps. The token requires only `contents: write` on the corpus repo.

**Non-blocking failure:** Telemetry push failure (network, conflict exhaustion, permission error) must never fail the quality gate itself. The push step exits 0 even on failure, emitting a `::warning::` annotation instead.

**Determinism:** The same quality gate JSON input produces the same telemetry output. The `telemetry-push` subcommand is deterministic given identical inputs.

**Safety:** No force unwraps, no force pushes. The retry loop uses `--rebase`, not `--force`. Corpus corruption from partial writes is prevented by `git commit` atomicity.

## 7. Source & API Compatibility

**Breaking changes:** None. The new workflow inputs (`telemetry-enabled`, `corpus-repo`, `corpus-branch`) all have defaults that preserve existing behavior. Callers that do not provide these inputs see zero change.

**Incremental adoption:** Yes. Projects enable telemetry by adding three lines to their workflow call (the `with:` inputs and `secrets:` block). No changes to `.quality-gate.yml`, no changes to project source code.

**Backward compatibility:** The reusable workflow remains callable without any telemetry inputs. The `telemetry-enabled` default of `false` ensures opt-in behavior.

## 8. Backend Abstraction

N/A -- this is CI workflow configuration, not compute-intensive code. No CPU/GPU/Accelerate considerations.

## 9. Dependencies

**Internal Dependencies:**
- `quality-gate telemetry-push` subcommand (delivered by IJS absorption proposal) -- the CLI command that transforms JSON gate output into corpus telemetry
- `quality-gate-reusable.yml` (existing) -- the reusable workflow being extended
- `--format json` CLI flag (existing) -- produces the JSON input for telemetry-push

**External Dependencies:**
- `actions/checkout@v4` -- already used, no new dependency
- A GitHub PAT or fine-grained token with `contents: write` on the corpus repo -- operational requirement, not a code dependency

**Sequencing Dependency:** The IJS absorption proposal must be implemented first. Specifically, the `quality-gate telemetry-push` subcommand must exist in the CLI before this workflow can invoke it.

## 10. Test Strategy

**Test Categories:**

- **Golden path (integration):** A quality gate run with `telemetry-enabled: true` produces a commit in the corpus repo containing valid `CheckResultMetadata` JSON and an updated `DailySnapshot`.
- **Opt-out (no regression):** A workflow call without `telemetry-enabled` produces no corpus checkout, no telemetry push, and identical behavior to today.
- **Conflict resolution:** Two concurrent pushes to the same corpus (simulated by running two workflow dispatches simultaneously) both succeed after rebase-and-retry.
- **Graceful degradation:** When `corpus-token` is invalid or missing, the telemetry step emits a warning but the quality gate exits with its normal status code (0 for pass, 1 for fail).
- **Empty diff:** When the quality gate results are identical to the previous run (no new telemetry), the push step skips the commit ("No telemetry changes to commit").

**Reference Truth:** The corpus file structure produced by `telemetry-push` is defined by the IJS absorption proposal. Validation compares the committed files against the `CorpusPath` directory layout (project directory, dated metadata files, daily snapshots).

**Validation Trace:**
- Run `quality-gate --check safety --format json > results.json` on a project with one warning
- Run `quality-gate telemetry-push --corpus-path /tmp/corpus --project-id test/repo --input results.json`
- Verify `/tmp/corpus/test/repo/telemetry/YYYY-MM-DD_HHMMSS.json` exists and contains the safety warning
- Verify `/tmp/corpus/test/repo/snapshots/YYYY-MM-DD.json` exists with `passCount: 0, failCount: 0, warningCount: 1`

**Testing approach:** Since this is CI infrastructure, testing is primarily done via:
1. A test workflow in quality-gate-swift itself that exercises the telemetry path against a test corpus repo
2. Manual workflow_dispatch runs to validate the retry logic
3. The quality-gate-swift dogfood workflow (`quality-gate.yml`) enabling telemetry push against its own corpus

## 11. Architecture Decision Review

**ADR Check:**
- [x] Reviewed `06_ARCHITECTURE_DECISIONS.md` for related decisions
- [ ] Does this supersede an existing ADR? No
- [ ] Does this amend an existing ADR? No
- [x] New ADR required? Yes -- draft entry below

**New ADR Draft:**
- Title: CI is the primary telemetry ingestion path, not local CLI
- Category: architecture
- Key decision: Telemetry push is integrated into the reusable CI workflow as the default and expected path, with local `telemetry-push` CLI invocation as a secondary option for development and debugging. This inverts the original IJS design where the CLI was the primary interface.

## 12. Adversarial Review

**Strongest case for a different approach:**
Use a GitHub App or webhook-based architecture instead of committing to a git repo from within the workflow. A dedicated telemetry service (HTTP API backed by a database) would eliminate all concurrency concerns, remove the need for PATs/deploy keys, support real-time dashboards, and decouple telemetry ingestion from git's serial commit model. The git-backed corpus is a deliberately simple choice that trades scalability and query performance for auditability and zero infrastructure cost -- but a critic would argue that "zero infrastructure" is misleading when you're managing PATs, retry loops, and concurrency groups in YAML.

**Where this design is most likely wrong:**
The assumption that rebase-and-retry with 3 attempts is sufficient for concurrent corpus writers. If an organization has 20+ repos all pushing telemetry on every PR, the contention window grows linearly and 3 retries may not be enough. The design degrades gracefully (telemetry is lost, not the gate result), but persistent contention would make the corpus incomplete and the Pulse unreliable. The mitigation (per-project concurrency groups in GitHub Actions) only serializes within a single project -- cross-project contention remains a real risk at scale.

**What an experienced critic would say:**
"You are building a distributed write system on top of git, which is a terrible database, and papering over its limitations with retry loops in shell scripts." We are proceeding because the corpus is append-mostly (each project writes to its own subdirectory), the write volume is low (one commit per CI run, not per second), and the auditability of git history is a genuine advantage for an institutional judgment system where every data point should be traceable to a specific CI run.

## 13. Alternatives Considered

**Alternative 1: HTTP-based telemetry service**
- Advantage: No concurrency issues, no git contention, real-time ingestion, supports database queries
- Disadvantage: Requires standing up and maintaining a server, managing authentication, paying for hosting, and the corpus loses its git-based auditability
- Why rejected: The IJS corpus is designed around git-backed auditability and zero infrastructure cost. An HTTP service is the right answer at scale (50+ repos) but premature for current usage. The migration path (swap the push step from git-commit to HTTP POST) is straightforward if needed later.

**Alternative 2: GitHub Actions artifact + scheduled consolidation**
- Advantage: No PAT needed -- each workflow uploads telemetry as an artifact, and a scheduled job consolidates artifacts into the corpus
- Disadvantage: Artifacts expire (90 days default), the consolidation job adds latency (telemetry is not available until the next scheduled run), and artifact-based architectures are fragile (the consolidation job must handle partial uploads, missing artifacts, and duplicate runs)
- Why rejected: Delayed ingestion defeats the purpose of the feedback loop. The Pulse should reflect the latest run, not yesterday's. The PAT requirement is a one-time setup cost that is well worth real-time telemetry.

**Alternative 3: Local git hook (post-push) as primary path**
- Advantage: No CI infrastructure changes, developers push telemetry from their own machines
- Disadvantage: Requires every developer to have corpus access and the hook installed, telemetry only fires when humans push (not on CI-only runs like scheduled builds or dependabot PRs), and there is no enforcement -- developers can skip hooks
- Why rejected: This was the original IJS design (manual CLI invocation) and it resulted in zero telemetry being collected. CI is the only path that fires reliably without human discipline. Local hooks remain a secondary option for developers who want immediate feedback.

**Alternative 4: Separate reusable workflow (not integrated into quality-gate-reusable.yml)**
- Advantage: Separation of concerns -- the quality gate workflow runs checks, a second workflow pushes telemetry. Each is independently consumable.
- Disadvantage: Consumers must wire up two workflow calls instead of one, pass the JSON output between them (which requires artifacts or outputs), and the telemetry workflow must rebuild quality-gate or download the binary from the first workflow. This doubles the CI complexity for every adopter.
- Why rejected: The whole point is zero friction. Integrating into the existing reusable workflow means adopters add three lines (`telemetry-enabled`, `corpus-repo`, `corpus-token`) and they are done. A separate workflow is available as a fallback for projects that use their own CI pipeline instead of the reusable workflow.

## 14. Future Directions

- **Corpus query MCP tool:** Expose the Institutional Pulse and consistency history as MCP tools so AI agents can query organizational patterns during code review.
- **Telemetry dashboard:** A static site generated from the corpus (GitHub Pages) showing trend lines, anomaly alerts, and per-project consistency scores.
- **Cross-project Pulse:** Aggregate telemetry across all repos in an organization into a single Institutional Pulse, enabling organization-wide pattern detection.
- **Webhook notification:** Post a summary to Slack or a GitHub Discussion when the Pulse detects a statistical anomaly (e.g., a project's consistency score drops below threshold).
- **Telemetry retention policy:** Automated pruning of old telemetry entries to keep the corpus repo size manageable, preserving only daily snapshots beyond a configurable horizon.
- **Branch-aware telemetry:** Tag telemetry entries with the branch name so the Pulse can distinguish main-branch quality from feature-branch churn.

## 15. Open Questions

1. **PAT vs. deploy key vs. GitHub App:** Which authentication mechanism should the documentation recommend? A fine-grained PAT scoped to `contents: write` on the corpus repo is simplest, but a GitHub App installation token would be more secure for organizations. Deploy keys work for single-repo access but require SSH setup in the workflow.

2. **Retry count and backoff:** Is 3 retries sufficient? Should there be exponential backoff (sleep between retries)? GitHub Actions shell steps have a 6-hour timeout, so aggressive retries are safe, but the UX of a workflow hanging on telemetry push is poor.

3. **Corpus repo initialization:** Should the reusable workflow handle creating the corpus repo structure (directories, initial Pulse) if it does not exist? Or should there be a one-time `quality-gate corpus-init` CLI command that adopters run manually?

4. **Telemetry on failed gates:** Should telemetry be pushed when the quality gate itself fails? The current design pushes regardless (failed runs are valuable data for the Pulse), but some adopters might prefer telemetry only on successful runs to avoid polluting the corpus with broken builds.

5. **Self-dogfooding timeline:** Should quality-gate-swift itself enable telemetry push in its `quality-gate.yml` before the reusable workflow is ready, using inline steps? This would validate the approach early but create duplication.

## 16. Documentation Strategy

**Documentation Type:** Narrative Article Required

**Complexity Threshold Check:**
- Does it combine 3+ APIs? Yes (reusable workflow inputs, CLI subcommand, corpus repo setup, GitHub secrets configuration)
- Does explanation require 50+ lines? Yes
- Does it need theory/background context? Yes (IJS feedback loop, corpus structure, concurrency model)

**Article Name:** `CITelemetrySetupGuide.md`
(Placed alongside the reusable workflow documentation. Covers: prerequisites, corpus repo creation, PAT/token setup, enabling telemetry in the workflow call, verifying the first push, troubleshooting common failures.)

---

**Date:** 2026-05-13
**Author:** Justin Purnell + Claude Opus 4.6
