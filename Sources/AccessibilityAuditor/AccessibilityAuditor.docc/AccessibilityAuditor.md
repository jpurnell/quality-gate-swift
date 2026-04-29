# ``AccessibilityAuditor``

Catches SwiftUI accessibility violations that exclude users with disabilities from using your app.

## Overview

AccessibilityAuditor uses SwiftSyntax to walk Swift source files and flag three categories of accessibility failure: missing VoiceOver labels, hardcoded font sizes that break Dynamic Type, and animations that ignore the user's Reduce Motion preference. Each rule maps to a real ability group (blind, low vision, motor, vestibular) documented in the Feature x Ability matrix below.

The auditor scans every `.swift` file under `Sources/` and reports warnings. It does not produce errors — accessibility issues are treated as warnings because context matters (a decorative image genuinely has no label). The suppression mechanism is the same `// SAFETY:` comment used by SafetyAuditor, keeping the workflow consistent across all quality-gate checkers.

### Feature x Ability matrix

Each enforced rule serves at least one user ability group. Features marked "design guideline" are best practices that require human review and are not statically enforceable.

| Feature | Low vision | Blind | Color blind | Motor | Hearing |
|:--------|:-----------|:------|:------------|:------|:--------|
| VoiceOver labels `[missing-accessibility-label]` | - | Primary UI | - | - | - |
| Dynamic Type `[fixed-font-size]` | Text scales | - | - | Larger targets | - |
| Reduce Motion `[missing-reduce-motion]` | Simplified | - | - | Less distraction | - |
| High Contrast `[design guideline]` | Sharper edges | - | Differentiation | - | - |
| Color-blind patterns `[design guideline]` | - | - | Shapes, not color | - | - |
| Switch Control `[design guideline]` | - | - | - | Full navigable | - |
| AudioNarrator `[design guideline]` | Supplement | Primary output | - | - | - |
| Visual indicators `[design guideline]` | - | - | - | - | Icons for SFX |
| Haptic cues `[design guideline]` | Supplement | Orientation | - | - | Audio sub. |
| Closed captions `[design guideline]` | - | - | - | - | Text for all |

### Detected rules

| Rule ID | Severity | What it catches |
|---------|----------|-----------------|
| `missing-accessibility-label` | warning | `Image(systemName:)` or `Image("name")` without `.accessibilityLabel()` or `.accessibilityHidden(true)` in the modifier chain |
| `fixed-font-size` | warning | `.font(.system(size: N))` instead of semantic text styles (`.body`, `.headline`, `.caption`, etc.) |
| `missing-reduce-motion` | warning | `withAnimation { ... }` or `.animation()` modifier without an `accessibilityReduceMotion` check within 10 lines |

### Configuration

The auditor respects two configuration knobs from `.quality-gate.yml`:

**Exclude patterns** — Skip files matching glob patterns:

```yaml
exclude_patterns:
  - "**/Generated/**"
  - "**/Previews/**"
```

**Safety exemptions** — Suppress a specific line with a comment:

```yaml
safety_exemptions:
  - "// SAFETY:"
```

A `// SAFETY:` comment on the same line or the line above a flagged expression suppresses that diagnostic and records a `DiagnosticOverride` in the result. The comment must explain why the violation is intentional.

### Out of scope

- Color contrast ratio analysis (requires runtime rendering, not static analysis)
- `.accessibilityHint()` completeness checks (planned for v2)
- Detecting missing `accessibilityElement(children:)` on custom container views
- Cross-file modifier chain analysis (would require IndexStore)
- Verifying that `.accessibilityLabel()` values are localized
- Switch Control reachability (requires full view hierarchy analysis)
- Closed caption or haptic cue coverage (design-time decisions, not code patterns)

## Topics

### Essentials

- ``AccessibilityAuditor/check(configuration:)``
- ``AccessibilityAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:AccessibilityAuditorGuide>
