# AccessibilityAuditor Guide

A practical walkthrough of every AccessibilityAuditor rule, with the SwiftUI patterns it catches and the recommended fixes.

## Why this auditor exists

Accessibility is not a feature you bolt on at the end. Every SwiftUI view that ships without VoiceOver labels, Dynamic Type support, or Reduce Motion checks excludes a real category of user:

1. **Blind users** rely on VoiceOver as their primary interface. An `Image(systemName: "star.fill")` without `.accessibilityLabel()` reads as "star.fill" or nothing at all — neither is useful.

2. **Low-vision and motor-impaired users** depend on Dynamic Type to scale text and enlarge tap targets. A hardcoded `.font(.system(size: 14))` defeats the system setting they configured for a reason.

3. **Users with vestibular disorders or motion sensitivity** need the Reduce Motion preference respected. A `withAnimation(.spring())` that ignores `accessibilityReduceMotion` can cause nausea or disorientation.

These are not edge cases. Roughly one in four adults in the US has a disability (CDC, 2023). AccessibilityAuditor catches the three most common SwiftUI accessibility failures at build time, before they ship.

## Rule walkthrough

### `missing-accessibility-label`

Every `Image(...)` in SwiftUI needs exactly one of two things: a `.accessibilityLabel()` that describes what the image conveys, or `.accessibilityHidden(true)` to tell VoiceOver to skip it entirely. Without either, VoiceOver reads the raw asset name or SF Symbol identifier, which is meaningless to a blind user.

The auditor walks the modifier chain upward from the `Image(...)` call expression. If neither `.accessibilityLabel()` nor `.accessibilityHidden()` appears anywhere in the chain, the rule fires.

```swift
// --- flagged ---

// VoiceOver reads "star.fill" — meaningless
Image(systemName: "star.fill")

// VoiceOver reads "hero-banner" — the asset catalog name
Image("hero-banner")

// .resizable() and .frame() don't help VoiceOver
Image(systemName: "checkmark.circle")
    .resizable()
    .frame(width: 24, height: 24)
```

```swift
// --- accepted ---

// Descriptive label for meaningful images
Image(systemName: "star.fill")
    .accessibilityLabel("Favorite")

// Decorative images hidden from VoiceOver
Image("hero-banner")
    .accessibilityHidden(true)

// Label anywhere in the modifier chain is fine
Image(systemName: "checkmark.circle")
    .resizable()
    .frame(width: 24, height: 24)
    .accessibilityLabel("Task complete")
```

**When the label matters**: If the image conveys information (status icons, action buttons, meaningful illustrations), it needs a label. If it is purely decorative (background textures, visual flourishes), hide it.

### `fixed-font-size`

`.font(.system(size: N))` pins text to an absolute point size, bypassing the user's Dynamic Type setting. Users who set their preferred text size to Extra Large or Accessibility Extra Extra Extra Large will see no change from your view. This affects low-vision users who need larger text and motor-impaired users who benefit from larger tap targets that scale with text.

The auditor detects any `.system(size:)` call — with or without weight or design parameters.

```swift
// --- flagged ---

// Fixed at 16pt regardless of the user's Dynamic Type setting
Text("Hello")
    .font(.system(size: 16))

// Fixed at 24pt bold — still ignores Dynamic Type
Text("Title")
    .font(.system(size: 24, weight: .bold))

// Even with a design parameter, the size is hardcoded
Text("Code")
    .font(.system(size: 14, design: .monospaced))
```

```swift
// --- accepted ---

// Semantic styles scale with Dynamic Type automatically
Text("Hello")
    .font(.body)

Text("Title")
    .font(.headline)

Text("Small print")
    .font(.caption)

// Custom fonts with relativeTo also scale
Text("Branded")
    .font(.custom("Avenir", size: 16, relativeTo: .body))
```

**The `relativeTo:` escape hatch**: If you need a custom font face, use `.font(.custom("Name", size: baseSize, relativeTo: .body))`. The `relativeTo:` parameter makes the custom font scale with Dynamic Type, which is the behavior you want.

**When fixed sizes are intentional**: Some layout elements (divider lines, fixed badges, measurement rulers) genuinely need a fixed size. Suppress with a `// SAFETY:` comment explaining why:

```swift
// SAFETY: Fixed size is intentional for this measurement ruler tick label
Text("0").font(.system(size: 8))
```

### `missing-reduce-motion`

`withAnimation { ... }` and the `.animation()` modifier trigger motion that some users cannot tolerate. The system-wide Reduce Motion setting (`UIAccessibility.isReduceMotionEnabled` on UIKit, `@Environment(\.accessibilityReduceMotion)` in SwiftUI) exists precisely for these users. Ignoring it is an accessibility failure.

The auditor looks for `withAnimation` calls and `.animation()` modifiers, then scans 10 lines above and below for any reference to `reduceMotion` or `accessibilityReduceMotion`. If no check is found nearby, the rule fires.

```swift
// --- flagged ---

// No reduceMotion check anywhere nearby
func toggle() {
    withAnimation(.spring()) {
        isExpanded.toggle()
    }
}

// .animation() modifier without a guard
Circle()
    .scaleEffect(isActive ? 1.2 : 1.0)
    .animation(.easeInOut, value: isActive)
```

```swift
// --- accepted ---

// Guard with @Environment and skip animation when requested
@Environment(\.accessibilityReduceMotion) var reduceMotion

func toggle() {
    withAnimation(reduceMotion ? nil : .spring()) {
        isExpanded.toggle()
    }
}

// Conditional modifier based on the preference
@Environment(\.accessibilityReduceMotion) var reduceMotion

var body: some View {
    Circle()
        .scaleEffect(isActive ? 1.2 : 1.0)
        .animation(reduceMotion ? nil : .easeInOut, value: isActive)
}
```

```swift
// --- also accepted ---

// The check can be a few lines away, not necessarily on the same line
@Environment(\.accessibilityReduceMotion) var reduceMotion

func animateTransition() {
    guard !reduceMotion else {
        // Apply the state change without animation
        isExpanded.toggle()
        return
    }
    withAnimation(.spring()) {
        isExpanded.toggle()
    }
}
```

**The 10-line radius**: The auditor scans 10 lines above and below the animation call. If your `reduceMotion` variable is declared further away (e.g., at the top of a 200-line struct), the check will still pass as long as the variable name `reduceMotion` or `accessibilityReduceMotion` appears somewhere within that radius. This means a `guard !reduceMotion` or `if reduceMotion` near the animation site is the cleanest pattern.

**Transitions and matched geometry**: The rule currently fires only for `withAnimation` and `.animation()`. It does not flag `.transition()`, `.matchedGeometryEffect`, or implicit animations from `.onChange`. These are planned for a future version.

## False positives and how to suppress them

The auditor uses the same `// SAFETY:` comment mechanism as SafetyAuditor. Place the comment on the same line or the line immediately above the flagged expression.

### `missing-accessibility-label` false positives

Images inside custom components that add their own accessibility label at a higher level:

```swift
// SAFETY: Parent ButtonStyle applies .accessibilityLabel("Play")
Image(systemName: "play.fill")
```

Image views used only in previews or design-time snapshots:

```swift
// SAFETY: Preview-only, not shipped to users
Image("placeholder-avatar")
```

### `fixed-font-size` false positives

Layout elements where scaling would break visual constraints:

```swift
// SAFETY: Badge counter is fixed to fit inside a 20pt circle
Text("\(count)").font(.system(size: 10))
```

### `missing-reduce-motion` false positives

Animations that are purely opacity changes (no motion):

```swift
// SAFETY: Opacity-only fade, no motion component
withAnimation(.easeIn(duration: 0.2)) {
    isVisible = true
}
```

Animations guarded by a custom motion preference that does not use the standard naming:

```swift
// SAFETY: Guarded by AppSettings.motionReduced (custom preference)
withAnimation(.default) {
    isOpen.toggle()
}
```

### When to suppress vs. when to fix

If you find yourself suppressing the same rule across many files, consider whether:

1. **`missing-accessibility-label`**: Your design system might need a wrapper that applies labels by default. Fix the component, not each call site.
2. **`fixed-font-size`**: You might need a design token system that maps to semantic text styles. Fix the token, not each usage.
3. **`missing-reduce-motion`**: You might need an animation helper that automatically checks the preference. Fix the helper, not each animation call.

If the rule is genuinely miscalibrated for your codebase, open an issue.
