# Development Guidelines - AI Assistant Instruction Set

**Purpose:** Reusable template for guiding AI assistants (Claude, etc.) in software development projects.

**How to Use:** Fork or copy this repository, then customize the `[PROJECT_NAME]` placeholders and project-specific content for your project.

---

## Quick Start

1. **Copy this template** to your project (as `development-guidelines/` or similar)
2. **Install git hooks (REQUIRED):** `./development-guidelines/scripts/install-hooks.sh`
3. **Install quality-gate** (if not already installed) — see [quality-gate-swift](https://github.com/jpurnell/quality-gate-swift)
4. **Copy CLAUDE.md template** (for Claude Code users): `cp development-guidelines/templates/CLAUDE.md ./CLAUDE.md`
5. **Replace `[PROJECT_NAME]`** with your actual project name throughout
6. **Customize `00_CORE_RULES/`** for your project's specific standards
7. **Add project roadmaps** to `01_ROADMAPS/`
8. **Track implementations** in `02_IMPLEMENTATION_PLANS/`

### Updating

To pull the latest framework files while preserving all project-specific documents:

```bash
./development-guidelines/scripts/update.sh
```

This updates core rules, scripts, and templates from GitHub. Your summaries, roadmaps, checklists, and plans are never touched.

---

## Folder Organization

### 00_CORE_RULES - **Read First, Reference Always**
Fundamental rules, guidelines, and standards that govern all development work.

| File | Purpose |
|------|---------|
| `00_MASTER_PLAN.md` | Project vision and architecture |
| `01_CODING_RULES.md` | Code style, patterns, and standards |
| `02_USAGE_EXAMPLES.md` | API usage patterns and examples |
| `03_DOCC_GUIDELINES.md` | Documentation standards (DocC) |
| `04_IMPLEMENTATION_CHECKLIST.md` | Task tracking (Design-First TDD workflow) |
| `05_DESIGN_PROPOSAL.md` | Architecture validation before coding |
| `07_SESSION_WORKFLOW.md` | **Context recovery and session protocols** |
| `08_FLOATING_POINT_FORMATTING.md` | Number formatting standards |
| `09_TEST_DRIVEN_DEVELOPMENT.md` | TDD approach and testing contract |
| `11_CI_QUALITY_GATE.md` | CI integration and reusable workflow |
| `12_ENFORCEMENT.md` | **Mechanical enforcement architecture** |
| `PERFORMANCE.md` | Performance guidelines |
| `RELEASE_CHECKLIST.md` | Release verification checklist |
| `TESTING.md` | Testing strategy |

### 01_ROADMAPS - **Strategic Planning**
Long-term strategic plans and phase roadmaps.

### 02_IMPLEMENTATION_PLANS - **Tactical Implementation**
Detailed implementation plans organized by status:
- `COMPLETED/` - Past implementations (for reference)
- `MIGRATIONS/` - Migration guides
- `UPCOMING/` - Planned work

### 03_STRATEGIES_AND_FRAMEWORKS - **High-Level Guidance**
Strategic documents for product direction and architecture.

### 04_LIBRARY - **Reference Materials**
Educational and reference materials (papers, tutorials, etc.)

### 05_SUMMARIES - **Session History**
Post-session summaries of completed work:
- `SESSION_SUMMARY_TEMPLATE.md` - **Template for session summaries**
- `05_00_PHASE_SUMMARIES/` - Phase completions
- `05_01_FIX_SUMMARIES/` - Bug fix summaries

### 06_BACKUP_FILES - **Archive**
Archived files for reference only.

---

## For AI Assistants (Claude, etc.)

> **📖 Full Protocol: [07_SESSION_WORKFLOW.md](00_CORE_RULES/07_SESSION_WORKFLOW.md)**

### Session Start — Context Recovery

Read documents in this order to recover context:

```
1. 00_MASTER_PLAN.md        → Vision and priorities
2. 01_CODING_RULES.md       → Forbidden patterns, safety rules
3. 09_TEST_DRIVEN_DEVELOPMENT.md → Testing contract
4. 04_IMPLEMENTATION_CHECKLIST.md → Current tasks
5. Latest file in 05_SUMMARIES/   → Where we left off
```

Then confirm: *"Context recovered. Current task is [X]. Ready to follow Zero Warnings Gate."*

### Development Workflow — Design-First TDD

```
0. DESIGN   → Propose architecture (see 05_DESIGN_PROPOSAL.md)
1. RED      → Write failing tests
2. GREEN    → Write minimum code to pass
3. REFACTOR → Improve code, keep tests green
4. DOCUMENT → DocC comments and examples
5. VERIFY   → Zero warnings/errors gate
```

### Session End — Handover Protocol

Before ending any session:

1. **Verify Quality Gate** — All checks pass (zero warnings, zero failures)
2. **Update State** — Move tasks in `04_IMPLEMENTATION_CHECKLIST.md`
3. **Create Summary** — New file in `05_SUMMARIES/` with:
   - Work completed
   - Quality gate status
   - **Immediate next step** (exact starting point for next session)
   - Pending blockers

### Decision Framework

| Task Type | Reference |
|-----------|-----------|
| New Feature | `05_DESIGN_PROPOSAL.md` → `04_IMPLEMENTATION_CHECKLIST.md` |
| Bug Fix | TDD approach, create summary in `05_01_FIX_SUMMARIES/` |
| Documentation | `03_DOCC_GUIDELINES.md` |
| Planning | `01_ROADMAPS/`, `02_IMPLEMENTATION_PLANS/` |
| Release | `RELEASE_CHECKLIST.md` (verification only) |

---

## Customization Guide

### Required Customizations

1. **`00_MASTER_PLAN.md`** - Replace with your project's vision and architecture
2. **`01_CODING_RULES.md`** - Adapt to your tech stack and conventions
3. **`02_USAGE_EXAMPLES.md`** - Add your project's API examples

### Optional Customizations

- Add project-specific guides to `00_CORE_RULES/`
- Create roadmaps in `01_ROADMAPS/`
- Add reference materials to `04_LIBRARY/`

---

## Branches

- **`main`** - Clean template with placeholders
- **`example`** - Working example (BusinessMath project) for reference

---

**Maintained By:** [Your Name]
**Template Version:** 1.0.0
