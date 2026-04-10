# Accessibility Quality Gate — Feature × Ability Matrix

This matrix maps each accessibility feature to the user abilities it
serves. The AccessibilityAuditor enforces the rules marked with a
`ruleId` below; the remaining features are design-time guidelines that
platform teams should follow.

```
┌────────────────────┬──────────────┬───────────────┬─────────────────────┬────────────────┬───────────────┐
│     Feature        │  Low vision  │     Blind     │    Color blind      │     Motor      │   Hearing     │
├────────────────────┼──────────────┼───────────────┼─────────────────────┼────────────────┼───────────────┤
│ VoiceOver labels   │ -            │ Primary UI    │ -                   │ -              │ -             │
│ [accessibility-    │              │               │                     │                │               │
│  label]            │              │               │                     │                │               │
├────────────────────┼──────────────┼───────────────┼─────────────────────┼────────────────┼───────────────┤
│ Dynamic Type       │ Text scales  │ -             │ -                   │ Larger tap     │ -             │
│ [fixed-font-size]  │              │               │                     │ targets        │               │
├────────────────────┼──────────────┼───────────────┼─────────────────────┼────────────────┼───────────────┤
│ High Contrast mode │ Sharper      │ -             │ Better              │ -              │ -             │
│ [design guideline] │ borders      │               │ differentiation     │                │               │
├────────────────────┼──────────────┼───────────────┼─────────────────────┼────────────────┼───────────────┤
│ Color-blind        │ -            │ -             │ Textures/shapes per │ -              │ -             │
│ patterns           │              │               │ player, not just    │                │               │
│ [design guideline] │              │               │ color               │                │               │
├────────────────────┼──────────────┼───────────────┼─────────────────────┼────────────────┼───────────────┤
│ Reduce Motion      │ Simplified   │ -             │ -                   │ Less           │ -             │
│ [missing-reduce-   │ animations   │               │                     │ distraction    │               │
│  motion]           │              │               │                     │                │               │
├────────────────────┼──────────────┼───────────────┼─────────────────────┼────────────────┼───────────────┤
│ Switch Control     │ -            │ -             │ -                   │ Full game      │ -             │
│ [design guideline] │              │               │                     │ playable via   │               │
│                    │              │               │                     │ switches       │               │
├────────────────────┼──────────────┼───────────────┼─────────────────────┼────────────────┼───────────────┤
│ AudioNarrator      │ Supplement   │ Primary game  │ -                   │ -              │ -             │
│ [design guideline] │              │ output        │                     │                │               │
├────────────────────┼──────────────┼───────────────┼─────────────────────┼────────────────┼───────────────┤
│ Visual combat      │ -            │ -             │ -                   │ -              │ Icons + text  │
│ indicators         │              │               │                     │                │ for every     │
│ [design guideline] │              │               │                     │                │ sound effect  │
├────────────────────┼──────────────┼───────────────┼─────────────────────┼────────────────┼───────────────┤
│ Haptic cues        │ Supplement   │ Orientation   │ -                   │ -              │ Substitute    │
│ [design guideline] │              │ aid           │                     │                │ for audio     │
├────────────────────┼──────────────┼───────────────┼─────────────────────┼────────────────┼───────────────┤
│ Closed captions    │ -            │ -             │ -                   │ -              │ All narration │
│ [design guideline] │              │               │                     │                │ has text      │
│                    │              │               │                     │                │ equivalent    │
└────────────────────┴──────────────┴───────────────┴─────────────────────┴────────────────┴───────────────┘
```

## Enforced rules (quality gate)

| Rule ID | Severity | What it detects | Suggested fix |
|:--------|:---------|:----------------|:--------------|
| `missing-accessibility-label` | warning | `Image(...)` without `.accessibilityLabel()` or `.accessibilityHidden(true)` | Add a descriptive label for screen readers, or mark decorative images as hidden |
| `fixed-font-size` | warning | `.font(.system(size: N))` instead of semantic text styles | Use `.font(.body)`, `.font(.headline)`, etc. for Dynamic Type support |
| `missing-reduce-motion` | warning | `withAnimation` or `.animation()` without a nearby `accessibilityReduceMotion` check | Guard with `@Environment(\.accessibilityReduceMotion)` and conditionally skip or simplify animations |

## Design-time guidelines (not yet enforced)

These are best practices that are difficult to detect via static analysis
but should be followed during code review:

- **High Contrast**: Use adaptive colors from asset catalogs; provide
  high-contrast variants for all custom colors.
- **Color-blind patterns**: Never use color as the sole differentiator.
  Add textures, shapes, or labels alongside color.
- **Switch Control**: All interactive elements must be reachable via
  sequential focus navigation. Avoid custom gesture-only interactions.
- **AudioNarrator**: Every game state transition should be describable
  in words. The `GameViewModel` API should expose enough context for
  natural-language narration.
- **Visual indicators**: Every sound effect should have a visual
  equivalent (icon, text flash, or badge). Never rely on audio alone.
- **Haptic cues**: Map game events to `HapticCue` values; platforms
  that support haptics render them, others skip silently.
- **Closed captions**: All spoken narration must have a text equivalent
  displayed on screen.

## Configuration

Exempt a line from accessibility checks with the same safety exemption
comment used by the SafetyAuditor:

```swift
// SAFETY: fixed size is intentional for this layout element
Text("X").font(.system(size: 8))
```
