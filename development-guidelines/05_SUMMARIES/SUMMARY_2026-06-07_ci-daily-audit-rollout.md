# Session Summary: CI Daily Audit Rollout (2026-06-07)

## Problem

The portfolio pulse suffered from sampling bias. Projects under active development ran quality-gate frequently, generating disproportionate telemetry (often non-compliant since they were mid-work). Stable, healthy projects ran once or twice locally, passed, and never ran again — their good scores disappeared under the volume of active-development noise. The pulse reflected development churn, not portfolio health.

## What Changed

### 1. `--corpus-path` CLI Flag (quality-gate-swift)

**File:** `Sources/QualityGateCLI/QualityGateCLI.swift`
**Commit:** `c861ab4` (quality-gate-swift, main)

Added `@Option(name: .long)` flag `--corpus-path` to the main quality-gate command. Overrides `consistency.corpusPath` from `.quality-gate.yml`. Required for CI where the corpus is checked out to an arbitrary path rather than the hardcoded local Dropbox path.

The override reconstructs the full `Configuration` with a new `ConsistencyCheckerConfig` containing the CLI-provided path while preserving all other consistency settings (projectID, threshold, riskTier, scorerWeights, exemptions).

### 2. `GenerateNarrative` Command (quality-gate-swift)

**File:** `Sources/QualityGateCLI/GenerateNarrative.swift` (new, ~440 lines)
**Registered in:** `Sources/QualityGateCLI/QualityGateCLI.swift` line 51
**Commit:** `c861ab4`

CLI subcommand `quality-gate generate-narrative` that:
- Loads the latest (or `--label`-specified) pulse from the corpus
- Loads the previous pulse for delta comparison
- Builds a structured prompt with tiers, weighted scores, trajectories, anomalies, group summaries
- Calls the Anthropic Messages API (`claude-sonnet-4-6` default) via URLSession
- Writes `NARRATIVE_<label>.md` with YAML frontmatter (label, generatedAt, model, templateVersion)
- Writes the narrative back into the pulse JSON via `InstitutionalPulse.withNarrative()`

**Dependencies:** Reads `ANTHROPIC_API_KEY` from environment. In launchd, loaded from macOS Keychain via `security find-generic-password`.

### 3. `InstitutionalPulse.withNarrative()` (IJSSensor)

**File:** `Sources/IJSSensor/InstitutionalPulse.swift`
**Commit:** `c861ab4`

Immutable copy helper that returns a new `InstitutionalPulse` with the `narrative` field set. Used by `GenerateNarrative` to write the LLM narrative back into the pulse JSON so the dashboard can display it (dashboard reads `pulse.narrative`, not the separate markdown file).

### 4. Reusable GitHub Actions Workflow (quality-gate-swift)

**File:** `.github/workflows/quality-gate-reusable.yml`
**Commit:** `c861ab4` (initial), `c388076` (self-check update)

Reusable workflow callable by any project via `uses: jpurnell/quality-gate-swift/.github/workflows/quality-gate-reusable.yml@main`. Inputs:

| Input | Default | Purpose |
|-------|---------|---------|
| `checks` | `""` (defaults) | Checker IDs to run, or `"all"` |
| `exclude` | `""` | Checkers to skip |
| `continue-on-failure` | `false` | Don't stop on first checker failure |
| `strict` | `false` | Treat warnings as errors |
| `config` | `.quality-gate.yml` | Config file path |
| `corpus-repo` | `""` | GitHub repo for telemetry (e.g., `jpurnell/org-judgement-corpus`) |
| `corpus-branch` | `main` | Branch to push telemetry to |

**Secret:** `corpus-token` — PAT with Contents read/write on the corpus repo.

**Flow:**
1. Checkout project
2. Setup Xcode (latest-stable)
3. Cache or build quality-gate binary from latest main
4. Checkout corpus repo (if configured)
5. Run quality-gate with `--corpus-path` pointing to the corpus checkout
6. Commit and push telemetry with retry logic (pull --rebase on conflict, 3 attempts)

### 5. Quality-Gate-Swift Self-Check Update

**File:** `.github/workflows/quality-gate.yml`
**Commit:** `c388076`

Updated the existing self-check workflow to:
- Add `schedule: cron: '0 6 * * *'` (daily at 6am UTC)
- Checkout org-judgement-corpus and pass `--corpus-path _corpus`
- Push telemetry after the check run
- Skip corpus operations on pull_request events (read-only)

### 6. Caller Workflow Template

**File:** `.github/workflows/quality-gate-caller.yml.template`
**Commit:** `c861ab4`

Template for consuming projects. Minimal YAML that calls the reusable workflow with `checks: "all"`, `continue-on-failure: true`, daily schedule, and corpus telemetry.

### 7. Launchd Pipeline Overhaul (org-judgement-system)

**File:** `Scripts/generate-pulse.sh`
**Commit:** `259f888` (org-judgement-system, main)

Complete rewrite of the pulse generation script. Previous version called `swift run ijs-telemetry refine`. New version:

- **Every 2-hour run:** Pull corpus from remote, commit any pending local telemetry, push
- **Once daily (first run):** Run `quality-gate generate-pulse --corpus-path`
- **Once daily at 8am+:** Run `quality-gate generate-narrative --corpus-path`
- **After generation:** Commit and push pulse output, run health check

Uses marker files (`.pulse-generated-YYYY-MM-DD`, `.narrative-generated-YYYY-MM-DD`) for once-daily deduplication. Loads `ANTHROPIC_API_KEY` from macOS Keychain for narrative generation.

### 8. Daily Audit Script (org-judgement-system)

**File:** `Scripts/daily-audit.sh` (new)
**Commit:** `259f888`

Local-machine sweep of all portfolio projects. Discovers projects via `find -name ".quality-gate.yml"`, runs `quality-gate --check all --continue-on-failure` in each, commits telemetry, clears the pulse marker so the next pulse cycle regenerates. Intended for launchd but superseded by CI approach for daily coverage.

### 9. Portfolio-Wide CI Rollout

**Date:** 2026-06-07
**Commits:** `ci: add daily quality gate with corpus telemetry` across 36 repos

Deployed `.github/workflows/quality-gate.yml` to every project with a GitHub remote:

**Standard caller workflow (35 repos):**
ApplesoftBASIC, ApplesoftBASICApp, CLWPro (CoverLetterWriter), geo-audit, iconquer, IconquerAI, IconquerApp, IconquerCLI, IconquerClient, IconquerCore, IconquerServer, IconquerTournament, jpurnell.github.io, BusinessMath-UI, BusinessMath, BusinessMathExcel, BusinessMathMarketData, BusinessMathPro, swiftMoE, SwiftXLSX, SwiftZIP (×2 checkouts, same repo), sicp-swift-companion, swift-potrace, SwiftCLIKit, docc-lint, GeoSEOMCP, org-judgement-system, project-showcase, quality-gate-types, SearchOperatorMCP, SwiftMCPClient, SwiftMCPServer, SwiftSVG, WineTaster-4

**Matrix workflow (1 repo — narbisEdge):**
Runs quality-gate in 10 directories: root `.`, BioFeedbackKit, BioFeedbackKit-EdgeBLE, BioFeedbackKit-HealthKit, BioFeedbackKit-HRBLE, BioFeedbackKit-Polar, EdgeSDK-Swift, NarbisKit, NarbisUI, NarbisWatchKit

**Not enrolled (no GitHub remote):**
businessMathMCP, houseMaker, IconquerGameKit, IconquerMatch, IconquerMCP, LedgeOS, StockOpt, DevGuidelinesMCP

**Not enrolled (not owned):**
Ignite (twostraws/Ignite), reunions2025 (Princeton2000/reunions2025)

### 10. `CORPUS_PUSH_TOKEN` Secret

A fine-grained GitHub PAT scoped to `jpurnell/org-judgement-corpus` with Contents read/write was created and set as a repository secret named `CORPUS_PUSH_TOKEN` on all 36 repos via `gh secret set`.

**Expiration:** 90 days from 2026-06-07 (renew by 2026-09-05).

## Rollback Procedure

### Full rollback (disable all CI quality gate runs)

```bash
# 1. Remove workflows from all repos
REPOS=(jpurnell/ApplesoftBASIC jpurnell/ApplesoftBASICApp jpurnell/CLWPro jpurnell/geo-audit jpurnell/iconquer jpurnell/IconquerAI jpurnell/IconquerApp jpurnell/IconquerCLI jpurnell/IconquerClient jpurnell/IconquerCore jpurnell/IconquerServer jpurnell/IconquerTournament jpurnell/jpurnell.github.io jpurnell/BusinessMath-UI jpurnell/BusinessMath jpurnell/BusinessMathExcel jpurnell/BusinessMathMarketData jpurnell/BusinessMathPro jpurnell/swiftMoE jpurnell/SwiftXLSX jpurnell/SwiftZIP jpurnell/sicp-swift-companion jpurnell/swift-potrace jpurnell/SwiftCLIKit jpurnell/docc-lint jpurnell/GeoSEOMCP jpurnell/org-judgement-system jpurnell/project-showcase jpurnell/quality-gate-types jpurnell/SearchOperatorMCP jpurnell/SwiftMCPClient jpurnell/SwiftMCPServer jpurnell/SwiftSVG jpurnell/WineTaster-4 jpurnell/narbisEdge)

for repo in "${REPOS[@]}"; do
  gh api "repos/$repo/contents/.github/workflows/quality-gate.yml" \
    --method DELETE \
    --field message="ci: remove quality gate workflow" \
    --field sha="$(gh api "repos/$repo/contents/.github/workflows/quality-gate.yml" --jq .sha)" \
    2>/dev/null || echo "skip: $repo"
done

# 2. Delete the secret from all repos
for repo in "${REPOS[@]}"; do
  gh secret delete CORPUS_PUSH_TOKEN --repo "$repo" 2>/dev/null
done

# 3. Revoke the PAT
# Go to https://github.com/settings/personal-access-tokens → quality-gate-corpus-push → Delete
```

### Partial rollback (disable specific repos)

```bash
# Remove workflow from one repo
REPO="jpurnell/SomeRepo"
gh api "repos/$REPO/contents/.github/workflows/quality-gate.yml" \
  --method DELETE \
  --field message="ci: remove quality gate workflow" \
  --field sha="$(gh api "repos/$REPO/contents/.github/workflows/quality-gate.yml" --jq .sha)"
```

### Rollback quality-gate-swift changes only

```bash
cd /path/to/quality-gate-swift
git revert c388076  # self-check telemetry + schedule
git revert c861ab4  # --corpus-path, GenerateNarrative, reusable workflow
git push
```

### Rollback org-judgement-system script changes

```bash
cd /path/to/org-judgement-system
git revert 259f888  # generate-pulse.sh overhaul + daily-audit.sh
git push
```

## Key Artifacts

| Artifact | Location |
|----------|----------|
| Reusable workflow | `quality-gate-swift/.github/workflows/quality-gate-reusable.yml` |
| Self-check workflow | `quality-gate-swift/.github/workflows/quality-gate.yml` |
| Caller template | `quality-gate-swift/.github/workflows/quality-gate-caller.yml.template` |
| Corpus push secret | `CORPUS_PUSH_TOKEN` on 36 repos (expires ~2026-09-05) |
| Pulse generation script | `org-judgement-system/Scripts/generate-pulse.sh` |
| Narrative command | `quality-gate-swift/Sources/QualityGateCLI/GenerateNarrative.swift` |
| Daily audit script | `org-judgement-system/Scripts/daily-audit.sh` |
| PAT management | GitHub Settings → Fine-grained tokens → `quality-gate-corpus-push` |

## Monitoring

- Check Actions tab on any enrolled repo to verify daily runs
- Check `org-judgement-corpus` commit history for `telemetry:` commits from `quality-gate[bot]`
- Pulse generation at 6am+ UTC should reflect CI telemetry from all 36 repos
- PAT expires ~2026-09-05 — all CI telemetry pushes will fail silently after expiry
