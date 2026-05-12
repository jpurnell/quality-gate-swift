# Design Proposal: Personal Judgment System (PJS)

## 1. Problem

People make hundreds of judgment calls a week. The consequential ones — where you override your own rules, choose between competing priorities, or act under uncertainty — are where growth happens. But almost nobody captures them. Journaling apps fail because they demand too much ceremony. Reflection practices fail because they rely on memory, which is unreliable and self-serving.

The result: most people repeat the same decision failures for years, lacking both the data and the vocabulary to see their own patterns.

## 2. Objective

Build a lightweight, cross-platform system that:
1. **Captures** consequential decisions with minimal friction (< 30 seconds)
2. **Stores** them as plain structured files in a synced folder (iCloud, Dropbox, Git)
3. **Generates** weekly and monthly Pulses via LLM analysis
4. **Surfaces** patterns, drift, and growth over time

Target users: anyone making decisions — from a 12-year-old learning metacognition to a team lead managing competing priorities.

## 3. Core Insight: The Vocabulary Gap

Most people can say "I made a bad decision" but can't articulate *which thinking capability* failed:

| Stage | Capability | Failure Mode |
|-------|-----------|--------------|
| **Goals** | Knowing what you want | Conflicting priorities, unexamined assumptions |
| **Problems** | Seeing what's in the way | Denial, blind spots, avoiding discomfort |
| **Diagnosis** | Understanding root causes | Blaming circumstances, shallow analysis |
| **Design** | Planning a solution | Choosing comfort over effectiveness |
| **Doing** | Executing the plan | Procrastination, distraction, breaking commitments |

This vocabulary (adapted from Dalio's five-step process) is the system's backbone. A kid who learns to say "I diagnosed the problem correctly but my design was wrong" at 12 has a 25-year head start on most adults.

## 4. Architecture

### 4.1 File Structure

```
~/Decisions/                          (synced via iCloud/Dropbox)
├── decisions/
│   ├── 2026/
│   │   ├── 04/
│   │   │   ├── 28/
│   │   │   │   ├── 0945_morning-routine-override.md
│   │   │   │   └── 1430_project-priority-call.md
│   │   │   └── 29/
│   │   │       └── 0800_difficult-conversation.md
│   │   └── ...
│   └── ...
├── pulses/
│   ├── weekly/
│   │   ├── 2026-W17.md
│   │   └── 2026-W18.md
│   └── monthly/
│       └── 2026-04.md
├── goals/
│   └── current.md                    (active goals, reviewed monthly)
├── patterns/
│   └── recurring.md                  (LLM-maintained pattern log)
└── config.md                         (preferences, categories, prompts)
```

### 4.2 Decision Entry (what the app generates)

```markdown
---
date: 2026-04-28T09:45:00
category: health
weight: significant
stage_failed: doing
---

## What I decided
Skipped the morning run even though I had time.

## What the alternative was
Run the planned 3 miles before work.

## Why
Felt tired. Told myself I'd go after work instead.

## What actually happened
Didn't go after work either. Fourth time this month.

## Root cause (process, not person)
The "I'll do it later" pattern — choosing short-term comfort at the cost of a commitment I made to myself. This is a *doing* failure, not a goals or design failure. I know what I want and I have a plan. I just don't execute when it's uncomfortable.
```

### 4.3 Decision Weights

Not every decision needs the same depth. Three tiers:

| Weight | Friction | When |
|--------|----------|------|
| **Quick** | Tap + 1 sentence | Small override: skipped a habit, chose the easier path |
| **Significant** | 3-4 prompts, ~30 sec | Meaningful choice: changed plans, said yes/no to something important |
| **Consequential** | Full entry, ~2 min | Life-affecting: career, relationship, financial, health turning point |

The app should make Quick entries nearly effortless — the goal is to lower the bar so you capture the small stuff, because that's where patterns live.

### 4.4 Weekly Pulse (LLM-generated)

The Pulse reads all decisions from the week plus the current goals file and generates:

```markdown
# Weekly Pulse: 2026-W18

## Consistency Score: 0.72

You made 14 captured decisions this week. 10 were consistent with
your stated goals. 4 showed drift.

## Patterns This Week

**Recurring: Morning execution gap (week 4 of 6)**
You've flagged "doing" failures around morning commitments in 4 of
the last 6 weeks. This isn't an event — it's a pattern. The root
cause is consistently "choosing comfort over commitment."

**New: Saying yes under social pressure**
Two decisions this week involved agreeing to things you didn't want
to do. Both cited "not wanting to disappoint" as the reason. Stage
failed: goals (you lost sight of your own priorities).

## Five-Step Distribution

| Stage | Failures | Trend |
|-------|----------|-------|
| Goals | 2 | ↑ new |
| Problems | 0 | — |
| Diagnosis | 0 | — |
| Design | 1 | ↓ improving |
| Doing | 3 | → persistent |

## Growth Signal

Your "design" failures dropped from 3/week to 1/week over the past
month. You're getting better at planning — the gap is now in
execution. That's progress, even though it might not feel like it.

## Question for Reflection

You've identified "choosing comfort" as a root cause 11 times in
6 weeks. What would it take to make the uncomfortable choice the
default? Is there a design change (environment, commitment device,
accountability) that would remove the decision point entirely?
```

### 4.5 Monthly Pulse

Aggregates weekly Pulses into trend analysis: which patterns resolved, which persisted, which are new. Updates the `patterns/recurring.md` file. Compares current month to goals.

## 5. The App

### 5.1 What It Does

The app's entire job is **removing the ceremony** of creating structured markdown. It is NOT a journal app. It's a capture tool.

Core interaction:
1. Open app (or widget/shortcut trigger)
2. See 3 prompts: *What did you decide?* / *What was the alternative?* / *Why?*
3. Optionally: tap a category, tap a weight, tap which stage failed
4. Hit save → structured markdown file appears in synced folder

The five-step stage selector could be a simple picker with one-line descriptions:
- "I didn't know what I wanted" → Goals
- "I didn't see the problem" → Problems  
- "I misunderstood the cause" → Diagnosis
- "My plan was wrong" → Design
- "I knew but didn't do it" → Doing

For a kid, this picker IS the product. It teaches metacognition through repeated use.

### 5.2 What It Doesn't Do

- No analytics dashboard (the Pulse is the analysis)
- No social features
- No gamification (streaks create perverse incentives to log noise)
- No cloud account (files sync via the user's existing service)
- No lock-in (it's markdown — leave anytime)

### 5.3 Platform Strategy

**Phase 1:** iOS app (SwiftUI) + iCloud Drive sync
- Widget for Quick entries (1 tap → fills template)
- Share Sheet integration (capture a decision in context)
- Shortcut action for automation

**Phase 2:** macOS companion (reads same folder)
- Pulse generation via Claude API or local LLM
- Pattern visualization (optional, simple)

**Phase 3:** Cross-platform
- Plain files mean any device with folder access works
- Web companion or Android app if demand warrants

### 5.4 Pulse Generation

Two options, not mutually exclusive:

**Option A: Claude API integration in app**
- Weekly notification: "Ready for your Pulse?"
- App sends the week's decisions + goals to Claude API
- Writes Pulse markdown to `pulses/weekly/`
- Cost: ~$0.02/week for typical usage

**Option B: Manual LLM conversation**
- User opens Claude/ChatGPT and says "Read my decisions folder and generate my weekly Pulse"
- Zero cost, works with any LLM, user controls the conversation
- Better for people who want to discuss the Pulse, not just receive it

**Option C: Automated background job**
- Shortcut/cron that runs weekly
- Calls Claude API with decisions + goals
- Writes Pulse file
- Sends push notification with summary

## 6. Adherence Strategy

This is the make-or-break question. Journaling apps have a 95% abandonment rate within 30 days. The PJS addresses this through:

### 6.1 Friction Reduction
- Quick entries take < 15 seconds
- No login, no sync setup (uses existing iCloud)
- Widget means you never need to open the app
- The five-step picker makes the "hard" part (reflection) into a simple tap

### 6.2 Value Delivery
- The weekly Pulse is the hook — people continue capturing because the Pulse is genuinely useful
- Seeing "you've flagged this pattern 4 weeks in a row" is more motivating than any streak counter
- The consistency score gives a single number to track without gamification

### 6.3 Minimum Viable Habit
- The system works with as few as 3-5 entries per week
- You don't need to capture everything �� just the decisions where you felt tension
- Missing a week is fine — the Pulse just says "light week, not enough data"

### 6.4 Social Accountability (Optional)
- Share your weekly Pulse with a mentor, coach, parent, or friend
- The Pulse is designed to be shareable — it's a summary, not a diary
- For kids: parent receives the Pulse, discusses it weekly

## 7. For Young People

The PJS is especially powerful for ages 10-18 because:

1. **Vocabulary acquisition** — Learning to say "I had a doing failure" instead of "I don't know what happened" is transformative
2. **Pattern recognition** — Seeing your own patterns in data is different from being told about them by adults
3. **Agency** — The system respects their decisions. It doesn't judge — it reflects. The consistency score says "here's what you did relative to what you said you wanted," not "here's what you did wrong"
4. **Metacognition practice** — The five-step picker is a metacognition exercise disguised as a UI element
5. **Growth visibility** — Monthly Pulses show improvement that's invisible day-to-day

The parent/mentor version: receive the kid's weekly Pulse (with their permission). Use it as a conversation starter, not a surveillance tool. "I noticed your Pulse said you had three 'doing' failures around homework this week. What do you think is going on?" is a very different conversation than "Why didn't you do your homework?"

## 8. Technical Decisions

- **Swift 6 + SwiftUI** — iOS-first, strict concurrency
- **No backend** — Files sync via iCloud Drive (CloudKit for the folder, not a database)
- **No database** — Markdown files are the database. Spotlight indexes them. Git versions them.
- **Claude API for Pulse** — Optional, not required. System works with manual LLM conversations
- **Open format** �� Markdown + YAML frontmatter. No proprietary formats. Export = your folder

## 9. What This Is NOT

- Not a therapy tool (no clinical claims, no health data)
- Not a productivity system (no tasks, no calendars, no GTD)
- Not a journal (no freeform writing, no prompts like "how do you feel")
- Not a habit tracker (no streaks, no gamification)

It's a **decision capture and reflection system** that helps you see your own thinking patterns over time.

## 10. Name Candidates

- Pulse (ties to the weekly Pulse concept)
- Five Steps (direct reference to the framework)
- Calibrate (what the system helps you do)
- Reflect (simple, clear)
- Mirror (the system shows you yourself)

## 11. Open Questions

1. **Privacy:** Decisions can be deeply personal. Encryption at rest? Or trust the user's device encryption?
2. **Sharing model:** How does a kid share Pulses with a parent without it feeling like surveillance?
3. **LLM dependency:** Should the Pulse work without an LLM (template-based) for users who don't want AI?
4. **Onboarding:** How do you teach the five-step model without it feeling like homework?
5. **Categories:** Should the system have default categories (health, work, relationships, money) or let users define their own?
