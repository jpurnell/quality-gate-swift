# App Skills Auditor Guide

Apple's skills bundle fails silently. This checker turns each silent failure into a finding.

## Why this checker exists

The Siri AI Developer Preview lets an app ship *skills*: short Markdown guides that tell Siri how to combine the app's tools. They live in a `.skillsbundle` directory. When a bundle is wrong it is not rejected at build time; it is just absent from what Siri sees. A skill folder named `Flight_Add`, a stray `README.md`, or a bundle that never reached the target's Copy Bundle Resources phase all produce an app that builds, runs, and has no skills.

`app-skills` reads the folders and, where an Xcode project exists, the project's resource phases. It runs nothing and is safe on a stranger's package. A project with no `.skillsbundle` is skipped, so it costs a project that does not use skills nothing.

## What a bundle looks like

```text
Skills.skillsbundle/
  flight-add/
    SKILL.md
  flight-search/
    SKILL.md
```

Each `SKILL.md` has frontmatter with exactly `name` and `description`, then a Markdown body.

## Rules

Every rule below is an error unless marked a note.

- `skills.bad-folder-name`: the folder name is not lowercase letters, digits and hyphens.
- `skills.missing-skill-md`: a skill folder with no `SKILL.md`.
- `skills.extra-files`: a skill folder holding anything besides `SKILL.md`. A `.DS_Store` is tolerated, since Finder writes one without being asked.
- `skills.frontmatter-fields`: no frontmatter, a key other than `name` and `description`, or either of those missing.
- `skills.body-too-long`: a body over 10,000 characters. Exactly 10,000 passes.
- `skills.duplicate-name`: the same skill name twice anywhere under the project. Reported on the second.
- `skills.bundle-not-in-target`: a bundle no target copies. A bundle inside a synchronized folder counts as copied unless the target's Resources phase excludes it.
- `skills.multiple-bundles`: a target that copies more than one bundle. Reported on each bundle after the first.
- `skills.names-type` (note): the body names an intent or entity type such as `AddToCartIntent`. Apple's guidance is to describe what the action does.

The two membership rules need an Xcode project. With none, or with one that could not be parsed, they are not judged: a bundle might be in the project that could not be read, and a guess would turn a missing rule into a wrong one.

## Not covered yet

`skills.unresolved-reference` and `skills.repeats-metadata` need a source format for skills and the tool descriptions to compare against. Neither exists yet, so neither rule does. The proposal that defines them is `OneReadinessManyCarriers.md` §4.4 and §4.5.

The checker also does not know whether Apple requires a skill's `name` to match its folder. It does not check that, because nothing read says so.

## Running it

```text
quality-gate --check app-skills
```

There is no configuration. Exclude the checker with `--exclude app-skills` if a project keeps unrelated `.skillsbundle` directories.
