# Design Proposal: Cross-Project Git-Backed Corpus

## 1. Objective

**Objective:** Replace the local file path corpus model with a remote git-backed corpus that supports cross-project institutional learning. A single git repository (`org-judgement-corpus`) stores all telemetry, snapshots, and Pulses for every project in the organization, with git history providing a full audit trail.

**Master Plan Reference:** This is the "Cross-project corpus" future direction identified in the IJS absorption proposal (section 14). It resolves the "Corpus in CI" open question from that same proposal (section 15).

## 2. Motivation

**Current situation:** The IJS corpus is configured via `ijs.corpusPath` — a local filesystem path. This works on a single developer machine but breaks in two critical scenarios:

1. **CI environments** — GitHub Actions runners have ephemeral filesystems. There is no persistent local path to accumulate telemetry across runs. The consistency checker must skip entirely.
2. **Cross-project learning** — the Pulse and consistency scoring are scoped to one project. An organization running quality-gate-swift on five repos has five isolated corpuses with no ability to detect patterns that span projects (e.g., "every repo overrides the same safety rule").

**Workaround:** In CI, the corpus is unavailable and the consistency checker returns `.passed` with an info note. Locally, developers must manually maintain and share the corpus directory. Cross-project analysis requires manually copying corpus data between directories.

**Drawback:** The institutional feedback loop — the core value proposition of the IJS — is inert in the environment where it matters most (CI). The per-project isolation means the "institutional" part of "Institutional Judgment System" is aspirational rather than operational.

## 3. Proposed Architecture

### New Files

```
Sources/IJSAggregator/
  CorpusManager.swift             — actor: clone, pull, commit, push via git CLI
  CorpusSource.swift              — enum: .remote(url), .local(path), .unavailable
  GitOperationError.swift         — structured errors for git failures
```

### Modified Files

```
Sources/IJSAggregator/
  CorpusPath.swift                — no structural change; basePath now points to the
                                    local clone of the remote repo
  TelemetryWriter.swift           — add commitAndPush() method after write operations

Sources/QualityGateCore/
  Configuration.swift             — extend IJSConfig with corpusURL: String? field
                                    (the existing corpusPath becomes the local clone
                                    location or fallback)

Sources/QualityGateCLI/
  QualityGateCLI.swift            — call CorpusManager.ensureCorpus() at startup,
                                    call commitAndPush() after telemetry emission
```

### Module Placement

All new types live in `IJSAggregator` — the module that already owns `CorpusPath` and `TelemetryWriter`. No new modules are introduced.

### Directory Structure (Corpus Repository)

The existing `org-judgement-corpus` layout already supports per-project subfolders. This proposal formalizes and extends it:

```
org-judgement-corpus/
  telemetry/
    quality-gate-swift/           # per-project subfolder
      2026-05-13/
        142300_metadata.json
        142300_calibration_0.json
    org-judgement-system/
      2026-04-28/
        230951_metadata.json
    narbis-ios/
      ...
  snapshots/
    corpus/                       # cross-project aggregate
      2026-05-13.json
    quality-gate-swift/           # per-project
      2026-05-13.json
    org-judgement-system/
      2026-04-28.json
  pulse/
    2026-W20/
      PULSE_2026-W20.json         # currently per-project; future: cross-project
```

### Branching Strategy

Each project pushes to its own branch (`project/<project-id>`), eliminating write contention entirely. A scheduled daily merge consolidates all project branches into `main`, and a weekly job generates the organizational Pulse from the merged view.

```
project/quality-gate-swift    ← CI pushes here (no conflicts)
project/org-judgement-system   ← CI pushes here (no conflicts)
project/narbis-ios             ← CI pushes here (no conflicts)
  |          |          |
  └──────────┴──────────┘
             |
    daily merge to main        ← scheduled job (GitHub Actions cron)
             |
             v
           main                ← clean cross-project snapshot
             |
    weekly Pulse generation    ← scheduled job reads main, writes Pulse
```

**Why per-project branches:** Concurrent CI runs across different projects can never conflict — each project's branch is exclusively owned. The daily merge is a fast-forward or trivial merge since projects write to non-overlapping subfolders. The weekly Pulse is the organizational review cadence.

### Data Flow

```
quality-gate run
  |
  v
CorpusManager.ensureCorpus()          # git clone (first run) or git pull
  |                                    # checks out project/<project-id> branch
  v
ConsistencyChecker.check()            # reads Pulse from main (latest merged state)
  |
  v
TelemetryWriter.write(...)            # writes metadata/calibrations to local clone
  |
  v
CorpusManager.commitAndPush(...)      # git add + commit + push to project branch
```

## 4. API Surface

```swift
/// Identifies how the corpus is accessed for this run.
public enum CorpusSource: Sendable, Equatable {
    /// Remote git repository, cloned locally.
    case remote(url: String, localClone: String)
    /// Local directory only (no git remote).
    case local(path: String)
    /// No corpus available; IJS features degrade gracefully.
    case unavailable
}

/// Manages the lifecycle of the corpus git repository.
public actor CorpusManager {

    /// Resolves the corpus source from configuration.
    ///
    /// If `corpusURL` is configured, clones or pulls the repo into a
    /// deterministic local path and checks out the `project/<projectID>`
    /// branch (creating it if needed). If only `corpusPath` is configured,
    /// uses it directly. If neither is set, returns `.unavailable`.
    public func ensureCorpus(
        corpusURL: String?,
        corpusPath: String?,
        projectID: String,
        projectRoot: String
    ) async throws -> CorpusSource

    /// Stages, commits, and pushes all changes to the project branch.
    ///
    /// Pushes to `project/<projectID>` — never directly to `main`.
    /// Commit message includes the project ID and timestamp for traceability.
    /// Push failures are logged but do not throw — a failed push leaves the
    /// commit in the local clone for the next run to retry.
    public func commitAndPush(
        source: CorpusSource,
        projectID: String,
        message: String
    ) async throws

    /// Merges all `project/*` branches into `main`.
    ///
    /// Intended for the daily scheduled job. Each project branch writes to
    /// non-overlapping subfolders, so merges are trivially conflict-free.
    /// After merging, pushes `main` to the remote.
    public func mergeProjectBranches() async throws
}

/// Extended IJSConfig (additions shown):
public struct IJSConfig: Sendable, Codable, Equatable {
    public let projectID: String?
    public let corpusPath: String?
    /// Git remote URL for the shared corpus repository.
    /// When set, the corpus is cloned/pulled from this URL.
    /// Takes precedence over corpusPath for the base directory.
    public let corpusURL: String?
    public let consistencyThreshold: Double?
    public let defaultRiskTier: Int?
    public let scorerWeights: ScorerWeightsConfig?
    public static let `default`: IJSConfig
}
```

### Configuration YAML

```yaml
ijs:
  projectID: quality-gate-swift
  corpusURL: git@github.com:jpurnell/org-judgement-corpus.git
  # corpusPath is optional: overrides the default clone location
  # (~/.quality-gate/corpus). Also serves as local-only fallback
  # when corpusURL is not set.
  corpusPath: ~/.quality-gate/corpus
  consistencyThreshold: 0.7
  defaultRiskTier: 2
```

## 5. MCP Schema

The corpus management operations are not exposed as MCP tools. They are internal infrastructure used by the consistency checker and telemetry writer.

For the IJS query interface (e.g., querying the Pulse, browsing telemetry), see the future IJSMCPTools proposal referenced in the IJS absorption proposal (section 14). That proposal would define MCP tools that read from the corpus — this proposal ensures the corpus is available and current when those tools are invoked.

## 6. Constraints & Compliance

**Concurrency:** `CorpusManager` is an actor. Git operations are serialized within it — no concurrent git commands against the same working tree. `TelemetryWriter` (already an actor) calls `CorpusManager` after writes.

**Determinism:** Git operations are inherently side-effectful. The design isolates all git I/O in `CorpusManager` so the rest of the IJS pipeline remains deterministic given the same corpus state on disk.

**Safety:** No force unwraps. Git CLI failures are caught and wrapped in `GitOperationError`. Path traversal protections in `TelemetryWriter.sanitizedURL(_:within:)` remain unchanged — the base path simply points to the local clone instead of a manually configured directory.

**Nonstandard design (external git dependency):** Most linters are self-contained. This tool requires a separate git repository for its institutional learning features. This is a deliberate choice: institutional memory requires persistence across runs, across machines, and across projects. A single repository cannot provide this. The git-backed corpus is opt-in — projects without `ijs.corpusURL` configured operate exactly as they do today.

**Git binary requirement:** `CorpusManager` shells out to the `git` CLI rather than linking a git library. This is acceptable because every environment where quality-gate-swift runs (developer machines, CI runners) already has `git` installed. It avoids adding a heavy dependency (libgit2/SwiftGit2) for a small number of operations.

## 7. Source & API Compatibility

**Breaking changes:** None. The existing `ijs.corpusPath` configuration continues to work unchanged. The new `ijs.corpusURL` field is additive.

**Incremental adoption:**
1. Projects with no IJS configuration: no change (consistency checker skips).
2. Projects with `ijs.corpusPath` only: no change (local corpus, no git operations).
3. Projects adding `ijs.corpusURL`: corpus is cloned/pulled automatically; telemetry is committed and pushed.

**Type-checking risk:** None — `CorpusSource` is a new enum, `CorpusManager` is a new actor, and `IJSConfig.corpusURL` is an additive optional property.

## 8. Backend Abstraction

N/A — this feature is I/O-bound (git CLI, filesystem reads/writes). No compute-intensive operations requiring GPU/Accelerate backends.

## 9. Dependencies

**Internal Dependencies:**
- `IJSAggregator` — `CorpusPath`, `TelemetryWriter` (modified)
- `QualityGateCore` — `Configuration`, `IJSConfig` (extended)
- `QualityGateCLI` — orchestration (modified)

**External Dependencies:**
- `git` CLI (runtime requirement, not a Swift package dependency). Present on all target platforms.
- No new Swift package dependencies.

## 10. Test Strategy

**Test Categories:**

- **Golden path:** `CorpusManager` clones a remote, pulls updates, commits and pushes telemetry. Verified using a temporary bare git repo created in the test fixture.
- **Local fallback:** When `corpusURL` is nil but `corpusPath` is set, `CorpusManager.ensureCorpus()` returns `.local(path:)` and no git operations occur.
- **Unavailable fallback:** When neither is configured, returns `.unavailable`. ConsistencyChecker returns `.passed` with info note.
- **Remote unavailable:** When `corpusURL` points to an unreachable remote, `ensureCorpus()` falls back to `.local` if the clone already exists, or `.unavailable` if not.
- **Push failure:** When push fails (e.g., network down), the commit remains in the local clone. No error propagated to the quality gate result.
- **Concurrent push (same project):** Two CI runs for the same project push to the same `project/<id>` branch simultaneously. The second push fails, retries with rebase, succeeds. (Tested with two `CorpusManager` instances against the same bare repo and branch.)
- **Concurrent push (different projects):** Two CI runs for different projects push to different branches simultaneously. Both succeed without interference.
- **Daily merge:** `mergeProjectBranches()` merges all `project/*` branches into `main`. Verified against a bare repo with 3 project branches writing to non-overlapping subfolders.
- **Path safety:** `TelemetryWriter.sanitizedURL` still rejects paths outside the corpus base, even when that base is a git clone.

**Reference Truth:** Git operations are validated by inspecting the bare test repo (commit log, file contents). No external math or statistics involved.

**Validation Trace:**
- Clone bare repo at `/tmp/test-corpus.git` → `ensureCorpus(corpusURL: "/tmp/test-corpus.git", ...)` → local clone exists at expected path with `.git/` directory
- Write metadata → `commitAndPush(...)` → bare repo has one new commit containing the metadata JSON
- Second clone at different path → `git pull` → same metadata file appears in second clone

## 11. Architecture Decision Review

**ADR Check:**
- [x] Reviewed `06_ARCHITECTURE_DECISIONS.md` for related decisions
- [ ] Does this supersede an existing ADR? No
- [ ] Does this amend an existing ADR? No — the IJS absorption ADR (from the IJS proposal) is about module structure, not corpus transport
- [x] New ADR required? Yes

**New ADR Draft:**
- Title: Git-backed remote corpus for cross-project IJS telemetry
- Category: architecture
- Key decision: The IJS corpus is persisted in a dedicated git repository rather than a local filesystem path, enabling cross-project institutional learning and CI compatibility via clone/pull/push operations managed by a `CorpusManager` actor.

## 12. Adversarial Review

**Strongest case for a different approach:**
A database-backed service (e.g., a small HTTP API backed by SQLite or Postgres) would solve the concurrency problem cleanly — no merge conflicts, atomic writes, proper query support. Git is being used as a poor man's database. A reviewer might argue that the git approach is clever-looking but fundamentally wrong for a data store that will see concurrent writes from CI.

Why we're proceeding with git anyway: the corpus is append-mostly (new telemetry files in unique timestamp-named paths), so merge conflicts are rare in practice. A database service adds an operational dependency (hosting, uptime, authentication) that is disproportionate for the current scale. Git repos are free, durable, and auditable. If scale demands it later, the `CorpusManager` actor is the seam where a database backend could be swapped in without changing any other code.

**Where this design is most likely wrong:**
The per-project branch strategy eliminates cross-project push conflicts, but same-project contention remains possible — if the same repo triggers multiple CI runs simultaneously (e.g., rapid pushes to different branches), two runs may push to the same `project/<id>` branch. This is rare (quality gate runs are typically triggered once per push) and mitigated by the existing rebase-and-retry logic, but it's the remaining contention surface.

A second fragile assumption: that the git CLI is available and functional in all CI environments. Containers without git would silently degrade to `.unavailable` — this is correct behavior but might confuse users who expect the corpus to work.

**What an experienced critic would say:**
"You're shelling out to git from an actor and pretending that's a clean abstraction — what happens when git prompts for credentials interactively and your process hangs?" We address this by always running git with `GIT_TERMINAL_PROMPT=0` and SSH with `BatchMode=yes`, ensuring non-interactive failure rather than hangs. The error is caught and surfaced as a `.unavailable` fallback with a diagnostic message.

## 13. Alternatives Considered

**Alternative 1: Database-backed corpus service (HTTP API)**
- Advantage: Proper concurrency control, queryable, no merge conflicts, could support real-time cross-project dashboards
- Disadvantage: Requires hosting infrastructure, authentication, uptime guarantees. Massive operational overhead for what is currently a small JSON file store.
- Why rejected: Operational cost is disproportionate. Git provides sufficient durability and auditability. The `CorpusManager` actor boundary makes a future migration to a service straightforward.

**Alternative 2: Cloud storage (S3 / GCS bucket)**
- Advantage: No merge conflicts (object storage is append-friendly), scales well, accessible from CI
- Disadvantage: Requires cloud credentials in every environment, no built-in history/audit trail, cost (even if small), vendor lock-in
- Why rejected: Git is already universally available and provides history for free. Every developer machine and CI runner has git; not all have cloud SDK credentials configured.

**Alternative 3: Keep local-only corpus, use CI artifacts for persistence**
- Advantage: No new infrastructure. CI artifacts (e.g., GitHub Actions cache) persist the corpus between runs.
- Disadvantage: Artifacts are scoped to a single repo's workflow — no cross-project visibility. Cache eviction policies are unpredictable. No audit trail.
- Why rejected: Fails the cross-project requirement entirely. Cache-based persistence is fragile and opaque.

**Alternative 4: Embed corpus data in the project's own git history**
- Advantage: Zero external dependencies — telemetry lives alongside the code it measures.
- Disadvantage: Pollutes the project's git history with telemetry commits. Cross-project aggregation requires reading N repos. Forces every contributor to pull telemetry data they may not need.
- Why rejected: Separation of concerns. The corpus is organizational infrastructure, not project source code.

## 14. Future Directions

- **Cross-project Pulse aggregation:** The weekly Pulse generation job reads `main` (which contains all projects' merged telemetry) and produces an organization-wide Pulse alongside per-project Pulses. The directory structure and daily merge cadence support this from day one; only the Refiner logic needs extension.
- **Sparse checkout optimization:** For large organizations, `CorpusManager` could use git sparse-checkout to clone only the current project's subfolder plus the `pulse/` directory, reducing clone size.
- **Corpus migration to a service:** If git contention on same-project branches becomes a bottleneck at scale, `CorpusManager` could be backed by an HTTP API instead of git CLI calls. The actor interface would remain identical.
- **Signed commits:** Telemetry commits could be GPG-signed to provide tamper-evident audit trails, ensuring that telemetry data has not been modified after the fact.
- **Pulse-driven alerts:** The weekly Pulse generation could trigger notifications (GitHub issue, Slack) when organizational consistency drops below a threshold or new violation clusters emerge.

## 15. Open Questions

- **Clone location:** Should the default local clone path be `~/.quality-gate/corpus` (user-global) or `<projectRoot>/.quality-gate/corpus` (per-project)? User-global avoids cloning once per project but could cause contention if multiple projects run simultaneously on the same machine. Per-project wastes disk but is isolated.
- **Push timing:** Should `commitAndPush()` run after every telemetry write (immediate consistency) or batch at the end of the full quality gate run (one commit with all artifacts)? Batching is more efficient but risks losing data if the process crashes mid-run.
- **Authentication in CI:** Should the proposal specify a recommended GitHub Actions workflow for corpus access (e.g., deploy key, PAT in secrets, GitHub App token)? Or leave this to the documentation?
- **~~Conflict resolution strategy:~~** Resolved by per-project branches. Cross-project conflicts are eliminated. Same-project contention (rare) uses `git pull --rebase` since telemetry files have unique timestamp-based names and should not conflict.
- **Corpus repo initialization:** Should `CorpusManager` be able to `git init` a new corpus repo and push it to a configured remote, or require the remote repo to already exist?
- **Daily merge job placement:** Should the daily merge-to-main job live in the corpus repo itself (`.github/workflows/daily-merge.yml`) or in quality-gate-swift's reusable workflow? Corpus repo is more natural since it's an operation on that repo.
- **Weekly Pulse cadence:** The organizational Pulse is generated weekly. Should this be a fixed day (e.g., Monday morning) or configurable? A fixed cadence simplifies the scheduled workflow and aligns with typical team retrospective cycles.

## 16. Documentation Strategy

**Documentation Type:** Narrative Article Required

**Complexity Threshold Check:**
- Does it combine 3+ APIs? Yes (CorpusManager, TelemetryWriter, Configuration, ConsistencyChecker, CLI orchestration)
- Does explanation require 50+ lines? Yes
- Does it need theory/background context? Yes (why a linter needs an external data store, git-as-database tradeoffs, CI integration patterns)

**Article Name:** `CrossProjectCorpusGuide.md`
(Placed in a ConsistencyChecker.docc or IJSAggregator.docc catalog. Must cover: configuration, local-only vs remote mode, CI setup with GitHub Actions example, troubleshooting git failures, and the degradation path when the corpus is unavailable.)
