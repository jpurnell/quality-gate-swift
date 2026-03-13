# Session Workflow & Context Recovery Protocol

**Purpose:** Ensure seamless context recovery and project continuity across AI sessions.

> **The Problem:** LLMs lose context between sessions. Without a protocol,
> each new session starts from scratch, potentially violating established
> architectural decisions or repeating resolved work.
>
> **The Solution:** Treat documentation as persistent memory. Every session
> ends with a checkpoint; every session starts by reading that checkpoint.

---

## Session Lifecycle

```
┌─────────────────────────────────────────────────────────────┐
│                    SESSION LIFECYCLE                         │
│                                                              │
│   ┌──────────────┐                                          │
│   │ SESSION START │──→ Context Recovery Protocol            │
│   └──────────────┘     (Read hierarchy, confirm readiness)   │
│          │                                                   │
│          ▼                                                   │
│   ┌──────────────┐                                          │
│   │ ACTIVE WORK  │──→ Design-First TDD                      │
│   └──────────────┘     (Design → Test → Implement → Doc)     │
│          │                                                   │
│          ▼                                                   │
│   ┌──────────────┐                                          │
│   │ SESSION END  │──→ Handover Protocol                     │
│   └──────────────┘     (Update state, create summary)        │
│          │                                                   │
│          ▼                                                   │
│   ┌──────────────┐                                          │
│   │ NEXT SESSION │──→ Reads summary, resumes exactly        │
│   └──────────────┘                                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Part 1: Session Start — Context Recovery Protocol

When starting a new session or recovering from a lost context window, the AI must read documents in this specific hierarchy:

### Reading Order (MANDATORY)

```
Vision → Constraints → State → History
```

| Order | Document | Purpose |
|-------|----------|---------|
| 1 | `00_MASTER_PLAN.md` | Understand project mission, users, priorities |
| 2 | `01_CODING_RULES.md` | Know forbidden patterns, safety requirements |
| 3 | `09_TEST_DRIVEN_DEVELOPMENT.md` | Understand testing contract, determinism rules |
| 4 | `04_IMPLEMENTATION_CHECKLIST.md` | See current In Progress and Blocked tasks |
| 5 | Latest file in `05_SUMMARIES/` | Catch up on exact stopping point |

### Context Recovery Prompt Template

Use this prompt to initialize a new AI session:

```markdown
We are resuming work on **[PROJECT_NAME]**. Please initialize your context
by reading the following documents in order:

1. **00_MASTER_PLAN.md**: Project mission, target users, current priorities
2. **01_CODING_RULES.md**: Forbidden patterns, division safety, Swift 6 concurrency
3. **09_TEST_DRIVEN_DEVELOPMENT.md**: LLM implementation contract, deterministic randomness
4. **04_IMPLEMENTATION_CHECKLIST.md**: Current 'In Progress' and 'Blocked' tasks
5. **The latest file in 05_SUMMARIES/**: Exact stopping point from last session

**Hardware Profile:** [CPU cores, RAM, GPU if relevant]
- Example: "10-core Apple Silicon, 32GB RAM — use 8 parallel test workers max"
- Affects: parallelization strategies, performance benchmarks, resource allocation

**Task:** Once read, provide a 3-sentence summary of our current objective
and confirm you are ready to follow the Zero Warnings/Errors Gate.
```

### AI Confirmation Response

After reading, the AI should confirm:

```markdown
**Context Recovered:**
1. Project: [Name] — [One-line mission]
2. Current Task: [From Implementation Checklist]
3. Last Session: [Summary of where we left off]

**Hardware Profile:** [cores] cores, [RAM] — [parallelization limit]

**Constraints Acknowledged:**
- Zero warnings/errors gate: ✅
- Deterministic randomness: ✅
- No force unwraps: ✅
- Design proposal required for non-trivial features: ✅

Ready to proceed.
```

---

## Part 2: Active Work — Design-First TDD

During active development, follow the workflow defined in:
- [Design Proposal Phase](05_DESIGN_PROPOSAL.md)
- [Implementation Checklist](04_IMPLEMENTATION_CHECKLIST.md)
- [Test-Driven Development](09_TEST_DRIVEN_DEVELOPMENT.md)

### Key Rules During Active Work

1. **Design Before Code:** Propose architecture for non-trivial features
2. **Tests Before Implementation:** Write failing tests first
3. **Zero Tolerance:** No warnings, no test failures, no unsafe patterns
4. **Document As You Go:** DocC comments immediately after implementation
5. **Track Progress:** Update Implementation Checklist as tasks complete

---

## Part 3: Session End — Handover Protocol

Before ending any session, complete the handover protocol to ensure the next session can resume seamlessly.

### Handover Checklist

```markdown
**Session End Checklist:**

- [ ] **Quality Gate Passed:**
  - [ ] `swift build` — zero warnings
  - [ ] `swift test` — zero failures
  - [ ] `swift build -Xswiftc -strict-concurrency=complete` — zero errors
  - [ ] `docc-lint` — zero issues

- [ ] **State Updated:**
  - [ ] `04_IMPLEMENTATION_CHECKLIST.md` — tasks moved to Completed/Blocked
  - [ ] `00_MASTER_PLAN.md` — updated if architecture changed

- [ ] **Session Summary Created:**
  - [ ] New file in `05_SUMMARIES/` using template
  - [ ] Filename: `YYYY-MM-DD_TaskName.md`
  - [ ] All sections completed
```

### Session End Prompt Template

Use this prompt to trigger proper session closure:

```markdown
We are ending this session. Please perform the handover tasks:

1. **Verify Quality Gate:** Run the zero warnings/errors checks and report status
2. **Update State Files:**
   - Move completed tasks in `04_IMPLEMENTATION_CHECKLIST.md`
   - Update `00_MASTER_PLAN.md` if we made architectural changes
3. **Create Session Summary:** Write a new file in `05_SUMMARIES/` including:
   - Work Completed (with test names, files modified)
   - Quality Gate Status (all checks)
   - Immediate Next Step (exact starting point for next session)
   - Pending Blockers (unresolved issues)
   - Context Loss Warnings (things the next session might forget)
```

### Session Summary Template

See: [SESSION_SUMMARY_TEMPLATE.md](../05_SUMMARIES/SESSION_SUMMARY_TEMPLATE.md)

---

## Part 4: Context Loss Prevention

### Why Context is Lost

| Cause | Prevention |
|-------|------------|
| Long conversation exceeds context window | Create checkpoint summaries mid-session |
| New session starts fresh | Always run Context Recovery Protocol |
| Architectural decisions forgotten | Document in Master Plan and Session Summary |
| Implicit assumptions | Make everything explicit in documentation |

### Mid-Session Checkpoints

For very long sessions, create intermediate checkpoints:

```markdown
**Mid-Session Checkpoint:**
- Work completed so far: [List]
- Current focus: [What we're working on now]
- Key decisions made: [List with rationale]
- Tests passing: [Count]
- Next step: [Immediate action]
```

### Critical Context to Preserve

Always document these explicitly — they're most likely to be forgotten:

1. **Why** something was done (not just what)
2. **Rejected alternatives** and why they were rejected
3. **Concurrency model** choices (actor vs struct, etc.)
4. **Seeds used** for stochastic tests
5. **External dependencies** and version constraints

---

## Part 5: Quick Reference

### Session Start Checklist
- [ ] Read documents in order (Vision → Constraints → State → History)
- [ ] Provide 3-sentence context summary
- [ ] Confirm Zero Gate commitment
- [ ] Identify immediate task from Implementation Checklist

### Session End Checklist
- [ ] All quality checks pass
- [ ] Implementation Checklist updated
- [ ] Session Summary created in `05_SUMMARIES/`
- [ ] Immediate next step clearly documented

### Emergency Context Recovery

If context is completely lost mid-conversation:

```markdown
"I've lost context. Please re-read:
1. The latest file in `05_SUMMARIES/`
2. `04_IMPLEMENTATION_CHECKLIST.md` — current tasks
3. Any files we modified this session: [list them]

Then summarize where we are and what we were doing."
```

---

## Part 6: Phase Summaries (Project State Sync)

As the project grows, individual session summaries may become insufficient for context recovery. Create **Phase Summaries** to consolidate state:

### When to Create a Phase Summary

- **Every 10 sessions** — Consolidate recent work
- **Upon completing a Roadmap Phase** — Document milestone achieved
- **Before major architectural changes** — Snapshot current state

### Phase Summary Location

Store in: `05_SUMMARIES/05_00_PHASE_SUMMARIES/`

Filename format: `YYYY-MM-DD_Phase[N]_[PhaseName].md`

### Phase Summary Contents

```markdown
# Phase [N] Summary: [Phase Name]

**Date Range:** [Start Date] to [End Date]
**Sessions Covered:** [Count]

## Objectives Achieved
- [Major feature 1] — complete with tests and docs
- [Major feature 2] — complete with tests and docs

## Architectural Decisions Made
| Decision | Rationale | Session |
|----------|-----------|---------|
| [Choice made] | [Why] | YYYY-MM-DD |

## Quality Gate Status
- Warnings: 0
- Test Failures: 0
- Concurrency Errors: 0

## Next Phase Priorities
1. [Next major objective]
2. [Next major objective]

## Context Loss Risks
- [Complex decisions that might be forgotten]
- [Implicit assumptions that should be explicit]
```

This prevents "context fragmentation" where the AI knows recent history but loses track of broader phase objectives.

---

## Related Documents

- [Master Plan](00_MASTER_PLAN.md) — Project vision
- [Coding Rules](01_CODING_RULES.md) — Implementation constraints
- [Design Proposal](05_DESIGN_PROPOSAL.md) — Architecture validation
- [Implementation Checklist](04_IMPLEMENTATION_CHECKLIST.md) — Task tracking
- [Test-Driven Development](09_TEST_DRIVEN_DEVELOPMENT.md) — Testing contract
- [Session Summary Template](../05_SUMMARIES/SESSION_SUMMARY_TEMPLATE.md) — Summary format
