# Design Proposal: Development Guidelines Skills

**Date:** 2026-05-15
**Status:** Proposed
**Author:** Claude (AI Assistant)

---

## Objective

Encode the development-guidelines process steps as Claude Code skills (slash commands) so the AI assistant is mechanically guided through each workflow phase rather than relying on memory or CLAUDE.md instructions.

**The question this proposal must answer:** Is this actually more valuable than what CLAUDE.md + hooks already provide?

---

## Proposed Skills

### `/design` — Design Proposal Workflow
Reads `05_DESIGN_PROPOSAL.md`, walks through each section, creates a proposal file in `02_IMPLEMENTATION_PLANS/PROPOSALS/`, includes adversarial review, and blocks implementation until the user approves.

### `/session-start` — Context Recovery
Offers `update.sh`, reads the 5 context documents in order, verifies hooks installed, confirms readiness.

### `/session-end` — Handover Protocol
Runs quality gate, updates implementation checklist, creates session summary in `05_SUMMARIES/`.

### `/verify` — Quality Gate Check
Runs `quality-gate --check all --exclude test --exclude doc-lint --strict --continue-on-failure` and reports results.

---

## Adversarial Review

### What problem do skills actually solve that we don't already have?

The enforcement stack today:
1. **Pre-commit hook** — mechanically blocks bad code from being committed
2. **CLAUDE.md** — loaded every session, contains inline rules and workflow
3. **Session workflow doc** — describes the process step by step
4. **Memory system** — remembers past corrections ("always run quality gate", "write design proposals first")

Skills would add: **interactive guidance through multi-step processes.**

### Where skills add value (honest assessment)

| Skill | Value over current system | Verdict |
|-------|--------------------------|---------|
| `/design` | Walks through the 10-section template. Without it, the AI must read the template and self-apply it — which I demonstrably failed to do today. A skill would force the structure. | **Marginal.** The failure today was ignoring the process, not misunderstanding it. A skill I choose not to invoke doesn't help. |
| `/session-start` | Runs update.sh, reads docs in order, confirms readiness. Currently the AI must remember to do this from CLAUDE.md. | **Low.** CLAUDE.md already says to do this. The skill just automates "read these 5 files" — which the AI can do from the instruction. |
| `/session-end` | Creates summary, runs quality gate, updates checklist. | **Low.** The pre-commit hook already blocks bad commits. The summary creation is the only unbacked step, and a skill won't force the user to invoke it. |
| `/verify` | Runs one command. | **None.** This is literally `quality-gate --check all --strict --continue-on-failure`. A skill wrapper adds nothing. |

### The core problem skills don't solve

Skills are **user-invoked**. The process failures we've seen are:
1. AI skips VERIFY step → **Fixed by pre-commit hook** (mechanical, automatic)
2. AI skips DESIGN step → **Not fixed by a `/design` skill** unless the AI or user remembers to invoke it
3. AI doesn't run session-start → **Not fixed by `/session-start`** unless invoked

The pattern: **mechanical enforcement (hooks) works because it's automatic. Skills fail for the same reason documents fail — they require someone to remember to use them.**

### Where a skill WOULD be valuable

A skill becomes valuable when:
1. The process is complex enough that even when invoked, the AI gets it wrong (design proposal with 10 sections + adversarial review)
2. The skill is invoked by a mechanical trigger, not human memory

Option (1) has some merit for `/design` — today I wrote a proposal that missed adversarial review, constraints, and documentation strategy. A skill that walks through each section as a checklist would catch that. But CLAUDE.md could also just say "follow the template in 05_DESIGN_PROPOSAL.md exactly" — which it already does.

Option (2) doesn't exist in Claude Code's current architecture. There's no "auto-invoke skill when the AI is about to create a new module."

### False sense of security risk

Adding skills could make the process feel more robust while actually adding no enforcement. If `/design` exists but isn't invoked, it's the same as having the document. Worse: it might make us less likely to add actual mechanical enforcement because "we have a skill for that."

---

## Recommendation

**Don't build the skills system.** The value is marginal for the implementation cost, and it doesn't solve the core problem (enforcement requires automation, not invocation).

Instead, invest in:

1. **Better CLAUDE.md instructions** — Make the design proposal requirement more explicit with a mechanical check: "Before creating any new directory under `Sources/`, write a design proposal first."

2. **A pre-commit check for proposals** — The quality gate could verify that any new SPM target in `Package.swift` has a corresponding file in `02_IMPLEMENTATION_PLANS/PROPOSALS/`. This would be actual mechanical enforcement.

3. **PostToolUse hook for new modules** — A Claude Code hook that fires when `mkdir Sources/NewModule` is run, checking for a proposal file. This is the automated trigger that skills can't provide.

### If we do build skills anyway

If the user decides skills are still worth it, `/design` is the only one with enough value to justify. The others are one-liners that CLAUDE.md handles fine. Keep the scope to one skill, not four.

---

## Open Questions

1. Is the real gap in the design proposal process a tooling problem or a discipline problem? If discipline, skills don't help.
2. Would a quality gate checker that validates "new module has a design proposal" be more valuable than a skill?
3. Are there other multi-step processes beyond design proposals where interactive guidance would genuinely help?
