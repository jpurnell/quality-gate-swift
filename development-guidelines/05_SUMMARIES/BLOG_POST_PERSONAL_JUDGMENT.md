# From Code Reviews to Life Reviews: A Personal Judgment System

We built an Institutional Judgment System for software teams — a four-layer feedback loop that captures override decisions, detects patterns statistically, and feeds institutional memory back into every quality gate run. It works. Teams that can see their own decision patterns make better decisions over time.

But here's what we didn't expect: the framework has nothing to do with software.

## The Framework Is the Point

The IJS is built on Ray Dalio's five-step process: Goals, Problems, Diagnosis, Design, Doing. When an engineer overrides a safety check, the system asks *which thinking capability failed* — not just "what went wrong." Did they lose sight of the goal? Fail to see the problem? Misdiagnose the root cause? Design a bad solution? Or know exactly what to do and not do it?

That taxonomy works for any decision. A missed workout. A conversation you avoided. A purchase you regret. A commitment you broke. Every one of these is a failure at a specific stage, and naming the stage is the first step toward not repeating it.

The institutional version generates weekly Pulses — statistical summaries of organizational decision quality. The personal version could do the same thing, but for you.

## What This Looks Like for a Team

Before we get personal, consider the non-software team. A sales organization makes dozens of judgment calls a week: which prospects to pursue, when to discount, whether to escalate. A product team chooses what to build, what to defer, what to kill. A leadership team allocates budget, hires, sets priorities.

These teams have the same problem the engineering team had: the reasoning behind decisions evaporates. The VP who approved the discount doesn't remember the trade-off six months later when the margin report lands. The product manager who killed the feature can't explain the reasoning to the new hire who asks why.

The IJS framework applies directly: capture the decision, classify the stage, generate a Pulse, surface the patterns. You don't need a Swift codebase or a quality gate. You need a way to write down "here's what I decided, here's what the alternative was, here's why, and here's which part of my thinking broke down."

But teams have accountability structures, meeting cadences, and shared artifacts that make capture natural. For an individual, you have none of that. You just have your own discipline — and discipline, as anyone who's tried journaling knows, is exactly what fails.

## The Adherence Problem

Journaling apps have roughly a 95% abandonment rate within 30 days. Reflection practices fail because they depend on memory, which is unreliable and self-serving. Habit trackers create perverse incentives — you log noise to maintain a streak, and the data becomes worthless.

The personal judgment system has to solve a different problem than the institutional one. The institutional version piggybacks on existing workflows — quality gates already run, so capturing the override decision adds minimal friction. A personal system has no existing workflow to piggyback on. You have to create the habit from nothing.

This means the capture mechanism isn't a nice-to-have. It's the entire product.

## Minimum Viable Capture

The insight is that most consequential personal decisions don't need a journal entry. They need a structured note that takes less time than the decision itself.

Three tiers:

**Quick** (< 15 seconds): You skipped a habit, chose the easier path, said yes when you meant no. One sentence. Tap the stage that failed. Done.

**Significant** (~30 seconds): You changed plans, made a commitment, chose between competing priorities. Three prompts: *What did you decide? What was the alternative? Why?* Tap a category, tap a weight, tap the stage.

**Consequential** (~2 minutes): A career move, a relationship decision, a financial turning point. Full entry with root cause analysis. These are rare — maybe one a month — and they're the ones you'll be most grateful you captured.

The key design constraint: a Quick entry must be faster than opening your notes app. If it's not, you won't do it when it matters — which is when you're in the middle of the decision you're compromising on, not when you're calmly reflecting later.

A widget. A share sheet. A Shortcut trigger. The app's job is to remove the ceremony of creating structured markdown, not to be a place you spend time.

## The Weekly Pulse

This is where the system earns its keep. An LLM reads your week's decisions — even just 3-5 of them — and generates a Pulse:

A **consistency score**: how many of your decisions aligned with your stated goals versus how many showed drift.

**Patterns**: "You've flagged 'choosing comfort over commitment' as a root cause 11 times in 6 weeks. This isn't an event — it's a pattern."

**Five-step distribution**: Where are your failures clustering? If they're all in Doing — you know what to do but don't do it — that's a fundamentally different problem than clustering in Goals — you don't know what you want.

**A reflection question**: Not a platitude. A specific question based on your actual data. "You've identified the same root cause 11 times. What would it take to make the uncomfortable choice the default? Is there a design change — environment, commitment device, accountability — that would remove the decision point entirely?"

The Pulse is the hook. People don't continue journaling because writing is rewarding. They continue because getting a clear, honest, pattern-aware summary of their own decision-making is genuinely useful — in a way that vague self-reflection never is.

## The Vocabulary Gap

Here's the part that gets me most excited. Most adults — smart, accomplished adults — can say "I made a bad decision" but cannot articulate *which thinking capability* failed. They lack the vocabulary.

- "I didn't know what I wanted" = Goals failure
- "I didn't see the problem" = Problems failure
- "I misunderstood the cause" = Diagnosis failure
- "My plan was wrong" = Design failure
- "I knew but didn't do it" = Doing failure

These are five fundamentally different failure modes requiring five fundamentally different interventions. Lumping them all into "I need to do better" is like a doctor treating every symptom with aspirin.

Now imagine a 12-year-old learning this vocabulary. A kid who can say "I diagnosed the problem correctly but my design was wrong" has a 25-year head start on most adults. They're not learning to journal. They're learning to think about their own thinking — metacognition — through a vocabulary that makes invisible processes visible.

For a kid, the five-step picker in the app IS the product. Every time they tap "I knew but didn't do it," they're practicing a cognitive skill that most adults never develop. And the weekly Pulse — shared with a parent or mentor, with the kid's permission — transforms the conversation from "why didn't you do your homework?" to "I noticed your Pulse said you had three Doing failures around homework this week. What do you think is going on?"

One conversation assigns blame. The other teaches reflection. Same data, completely different relationship.

## Plain Files, No Lock-In

The personal system uses the same philosophy as the institutional one: plain markdown files in a synced folder. No database. No cloud account. No lock-in.

```
~/Decisions/
  decisions/2026/04/28/0945_morning-routine-override.md
  decisions/2026/04/28/1430_project-priority-call.md
  pulses/weekly/2026-W18.md
  pulses/monthly/2026-04.md
  goals/current.md
  patterns/recurring.md
```

Every decision is a markdown file with YAML frontmatter: date, category, weight, stage failed. Every Pulse is a markdown file. Your goals are a markdown file. Export means copying a folder. Migration means opening the files in any text editor on any device.

This matters because a personal judgment system is a 10-year tool, not a 10-month subscription. The data you capture at 25 should be readable at 45 — without needing a company to still exist, an API to still be running, or a format to still be supported.

## The LLM as Analyst, Not Oracle

The Pulse generation works with any LLM. Claude, ChatGPT, a local model — it reads your week's markdown files and generates the summary. Cost at current API pricing: roughly two cents per week.

But here's the important part: the LLM isn't telling you what to do. It's reflecting what you did. The consistency score isn't a judgment — it's arithmetic. The pattern detection isn't advice — it's observation. The reflection question isn't prescriptive — it's Socratic.

This distinction matters because the moment the system starts telling you what you *should* decide, it stops being a judgment system and becomes a crutch. The goal is calibration — helping you see your own patterns so you can decide what to do about them. Not outsourcing the deciding.

For users who don't want AI involved at all, the system still works. The structured capture alone — the act of classifying your decisions by stage and weight — builds the metacognition muscle. The Pulse just accelerates the pattern recognition.

## What We're Building

The personal judgment system is a new project — an iOS app (SwiftUI, iCloud sync, no backend) that does one thing: removes the ceremony of creating structured decision files. Widget for quick entries. Three prompts for significant ones. A five-step picker that teaches metacognition through repeated use.

The institutional version took 33 types, 258 tests, and four architectural layers. The personal version needs to be simpler by an order of magnitude. The capture app is the hard part — not technically, but in terms of making it frictionless enough that people actually use it in the moment of decision, not two hours later when the rationalizing has already started.

The weekly Pulse is a Claude API call away. The real challenge is the same one every personal development tool faces: getting people to show up consistently for something that benefits their future self at the cost of their present self's time.

Our bet is that the Pulse solves this. Not through streaks or gamification — those create perverse incentives to log noise. Through genuine value: a weekly mirror that shows you your own thinking patterns with a clarity that memory and self-reflection can't match.

Most people repeat the same decision failures for years. Not because they're incapable of learning, but because they lack the data and the vocabulary to see what's happening. A structured capture tool plus an analytical Pulse gives them both.

The question was never "how do we make better decisions?" It was "how do we make our decision patterns visible enough that improvement becomes possible?"

---

*This is the second in a series. The first post covers the [Institutional Judgment System](BLOG_POST_INSTITUTIONAL_JUDGMENT.md) for software teams. The personal system is currently in design — the proposal is [here](../02_IMPLEMENTATION_PLANS/PROPOSALS/PersonalJudgmentSystem.md).*
