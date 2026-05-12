# Design Proposal: ViewInspector UI Unit Testing

## 1. Objective

**Objective:** Add ViewInspector as an optional test dependency to enable unit-level SwiftUI view testing without requiring a simulator or host app. This closes the verification gap where views compile but render incorrectly — catching state propagation bugs, missing modifiers, and broken view hierarchies before manual testing.

**Problem Statement:** Across multiple projects (biofeedback app, iConquer, SwiftCLIKit), UI features were marked "implemented" but failed on first manual build. Root causes were consistently:
- `@State` / `@Binding` not propagating correctly
- Modifiers applied in wrong order or on wrong view type
- Conditional views not rendering for expected states
- Missing environment objects or environment values

These are all testable without rendering pixels — they're structural and state-management bugs.

## 2. Proposed Architecture

**New Dependency:**
```swift
// Package.swift (test target only)
.package(url: "https://github.com/nalexn/ViewInspector.git", from: "0.10.0"),
```

**No new source files.** ViewInspector is a test-only dependency. Tests live alongside existing test targets.

**Modified Files:**
- `Package.swift` — add ViewInspector dependency to test target(s)
- `00_CORE_RULES/09_TEST_DRIVEN_DEVELOPMENT.md` — add UI testing section
- `00_CORE_RULES/10_APPLICATION_TESTING_PATTERNS.md` — update testing pyramid

**Test File Convention:**
```
Tests/
  <ModuleName>Tests/
    Views/
      <ViewName>Tests.swift      // ViewInspector tests per view
      StateMatrixTests.swift     // State-matrix coverage (see companion proposal)
```

## 3. API Surface

ViewInspector is a test-only library — no public API changes to any project.

**Test API patterns to standardize:**

```swift
import Testing
import ViewInspector
@testable import MyApp

@Suite("SettingsView Tests")
struct SettingsViewTests {

    @Test("displays volume slider with correct initial value")
    @MainActor
    func volumeSliderInitialValue() throws {
        let view = SettingsView(volume: .constant(0.75))
        let slider = try view.inspect().find(ViewType.Slider.self)
        // ViewInspector lets us verify the slider exists in the hierarchy
    }

    @Test("toggle updates binding")
    @MainActor
    func toggleUpdatesBinding() throws {
        var isEnabled = false
        let binding = Binding(get: { isEnabled }, set: { isEnabled = $0 })
        let view = SettingsView(notificationsEnabled: binding)

        let toggle = try view.inspect().find(ViewType.Toggle.self)
        try toggle.tap()

        #expect(isEnabled == true)
    }

    @Test("error state shows alert text")
    @MainActor
    func errorStateShowsAlert() throws {
        let view = SettingsView(errorMessage: "Connection failed")
        let text = try view.inspect().find(text: "Connection failed")
        // View hierarchy contains the error message
        _ = text
    }
}
```

## 4. MCP Schema

Not applicable — this is a testing infrastructure change, not a user-facing API.

## 5. Constraints & Compliance

**Concurrency:** All ViewInspector tests require `@MainActor` because SwiftUI views are `@MainActor`-isolated. This aligns with the existing pattern documented in project memory.

**Swift Testing:** ViewInspector works with Swift Testing (`import Testing`). Tests use `#expect` and `@Test`, never XCTest.

**No Simulator Required:** ViewInspector operates on view descriptions, not rendered pixels. Tests run in `swift test` without Xcode or a simulator.

**Test-Only Dependency:** ViewInspector is added only to test targets. It never ships in production binaries.

**Swift Version:** Verify ViewInspector compatibility with both local (6.3) and CI (6.0.x) Swift toolchains before adoption.

## 6. Backend Abstraction

Not applicable.

## 7. Dependencies

**Internal Dependencies:** None

**External Dependencies:**
- [ViewInspector](https://github.com/nalexn/ViewInspector) (test-only, MIT license)
- Requires Swift 5.9+ (compatible with our toolchain)

**Risk:** ViewInspector tracks SwiftUI's internal structure. Major SwiftUI releases can break it temporarily. Mitigation: pin to a known-good version, update deliberately.

## 8. Test Strategy

**Test Categories for ViewInspector Tests Themselves:**

ViewInspector is the test tool — the "tests" are the view tests written per-project. The development guidelines should mandate these categories for every interactive SwiftUI view:

### Required View Test Categories

| Category | What to verify | Example |
|----------|---------------|---------|
| **Structure** | Expected subviews exist in hierarchy | "SettingsView contains a Slider and two Toggles" |
| **State binding** | Interactions update bindings correctly | "Tapping toggle flips the binding value" |
| **Conditional rendering** | Correct views shown per state | "Error banner visible when errorMessage != nil" |
| **Modifier presence** | Critical modifiers applied | ".disabled(true) when isLoading" |
| **Environment dependency** | View behaves correctly with injected environment | "Uses colorScheme from environment" |

### What NOT to Test with ViewInspector

- Pixel-perfect layout, spacing, colors (use snapshot tests)
- Animation timing or transitions
- Platform-specific rendering differences
- Navigation destination rendering (test navigation logic separately)

**Reference Truth:** The SwiftUI view source code is the reference. Tests verify that the declared view body produces the expected hierarchy and responds to state changes as designed.

## 9. Architecture Decision Review

**ADR Check:**
- [x] No existing ADR for UI testing
- [ ] Does not supersede an existing ADR
- [ ] Does not amend an existing ADR
- [x] New ADR required

**New ADR Draft:**
- Title: UI View Testing with ViewInspector
- Category: testing
- Key decision: Use ViewInspector for structural/state unit tests of SwiftUI views; reserve snapshot tests for visual regression; do not rely solely on manual testing for UI correctness.

## 10. Open Questions

1. ~~**ViewInspector fork status:**~~ **RESOLVED** — ViewInspector is managed within the development-guidelines project at `/Users/jpurnell/Dropbox/Computer/Development/Swift/Tools/development-guidelines`. Pin to a known-good version and verify compatibility with local (6.3) and CI (6.0.x) toolchains before first adoption in a project.
2. **Custom view inspection:** For complex custom views, ViewInspector may require `Inspectable` protocol conformance. Should this be added to production types or handled via test extensions?
3. ~~**Coverage scope:**~~ **RESOLVED** — ViewInspector tests are mandatory for **all** SwiftUI views, not just interactive ones. Consistency across the codebase outweighs the marginal cost of testing simpler views.

## 11. Documentation Strategy

**Documentation Type:** Narrative Article Required

**Complexity Threshold Check:**
- Does it combine 3+ APIs? Yes (ViewInspector + Swift Testing + SwiftUI)
- Does explanation require 50+ lines? Yes
- Does it need theory/background context? Yes (what ViewInspector can/cannot test)

**Article Name:** `UITestingGuide.md` (new core rules document: `00_CORE_RULES/12_UI_TESTING.md`)

This document would cover:
- When to use ViewInspector vs. snapshot tests vs. manual testing
- Required test categories per view type
- State-matrix coverage requirements (see companion proposal)
- Common patterns and anti-patterns
- `@MainActor` requirements and Swift concurrency considerations
