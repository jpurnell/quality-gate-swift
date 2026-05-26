# HIG Auditor: Programmatic Human Interface Guidelines Compliance for SwiftUI Apps

**Date:** 2026-05-22
**Context:** Quality-gate-swift enforces code safety, concurrency, and style — but not UX quality. Apple's Human Interface Guidelines define clear, platform-specific expectations for how apps should look and behave on macOS, iOS, iPadOS, visionOS, tvOS, and watchOS. This proposal turns those guidelines into enforceable, cross-platform quality-gate rules.

**Motivation:** The Mac community coined "Mac-assed Mac app" to describe apps that truly honor macOS conventions — but the principle applies everywhere. An iPad app that ignores keyboard shortcuts or a visionOS app that removes its glass background is equally broken from a platform-fidelity standpoint. A quality gate that only checks code correctness misses an entire dimension of quality.

**Sources:**
- Apple HIG: Windows, Designing for macOS, Keyboards, The Menu Bar, Split Views, Sidebars, Tab Bars, Context Menus, Focus and Selection, Drag and Drop, Settings, Undo and Redo, Toolbars, Mac Catalyst
- pfandrade.me: "Mac-assed SwiftUI app" (inactive window states, selection, drag, keyboard nav, toolbar placement)
- Brent Simmons / John Gruber on "Mac-assed Mac apps" (platform-native over cross-platform)

**Status:** Draft — some rules (especially around materials and vibrancy) may need updates for Liquid Glass in OS 27. The rule set is designed to be additive.

---

## The Problem, Concretely

A developer builds a SwiftUI app. It compiles, tests pass, quality-gate reports 0 errors / 0 warnings. They ship it. Platform-native users immediately notice problems:

**On macOS:**
- No keyboard shortcuts. Cmd-comma does nothing. Cmd-N does nothing.
- No menu bar beyond the auto-generated app menu. Can't discover features.
- One fixed-size window. Can't resize, can't open a second window.
- No context menus on list items. Right-click does nothing.
- No tooltips. Hover over toolbar buttons — nothing.
- `NavigationStack` everywhere — the app looks like a blown-up iPhone app.
- Inactive windows look identical to the active one.

**On iPadOS:**
- No keyboard shortcuts, even with a Magic Keyboard attached.
- `NavigationStack` instead of `NavigationSplitView` — wastes the large display.
- No drag-and-drop support between panes or apps.
- No menu bar commands — the iPadOS 16+ menu bar is completely empty.

**On visionOS:**
- Opaque background instead of the required glass material.
- Window too large or too small — no min/max constraints.
- No ornaments for high-value controls.

**On tvOS:**
- Custom focus effects instead of system parallax — breaks the Siri Remote experience.
- Tab bar used for actions instead of navigation.

The app is *correct* but not *platform-native*. Our quality gate says nothing about this.

### What the HIG Actually Requires

From "Designing for macOS":
> "Use the menu bar to give people easy access to all the commands they need."
> "Handle keyboard shortcuts to help people accelerate actions."

From "Tab Bars" (iOS/iPadOS):
> "Use a tab bar to support navigation, not to provide actions."
> "Don't disable or hide tab bar buttons, even when their content is unavailable."

From "Windows" (visionOS):
> "Retain the window's glass background."
> "Choose an initial window size that minimizes empty areas."

From "Focus and Selection" (tvOS):
> "Rely on system-provided focus effects."
> "Be consistent with the platform as you help people bring focus to items."

From "Keyboards" (cross-platform):
> "Support Full Keyboard Access when possible."
> "Respect standard keyboard shortcuts."

These aren't aspirational — they're baseline expectations.

---

## What Existing Auditors Can't Catch

| Gap | Nearest Existing Checker | Why It Misses |
|-----|-------------------------|---------------|
| Missing Settings scene | None | No auditor inspects `@main` App struct |
| Missing menu bar commands | None | No auditor looks for `.commands {}` |
| Missing keyboard shortcuts | None | Modifiers on Button/ToolbarItem not checked |
| Wrong navigation pattern | None | No platform-appropriate control checks |
| Missing tooltips | AccessibilityAuditor | Checks a11y labels, not `.help()` tooltips |
| Missing context menus | None | No auditor checks for `.contextMenu` on list items |
| No multi-window support | None | Window architecture not inspected |
| Hardcoded colors | None | Color usage not checked for semantic correctness |
| Tab bar misuse | None | No check for actions-in-tabs anti-pattern |
| visionOS glass removal | None | No check for opaque backgrounds in volumes |
| Custom focus effects on tvOS | None | Focus customization not inspected |

---

## Proposed Solution: `HIGAuditor`

A new `QualityChecker` (implementing `FixableChecker` for auto-fix support) that uses SwiftSyntax to walk SwiftUI source files and enforce HIG compliance. Every rule is tagged with its applicable platforms so the auditor can run correctly whether the project targets one platform or all of them.

### Checker ID and CLI Integration

```
quality-gate --check hig-auditor --strict
quality-gate --check hig-auditor --strict --platform macOS
quality-gate --check hig-auditor --strict --platform iOS,macOS
```

- **id:** `hig-auditor`
- **name:** `HIG Auditor`
- **Exemption comment:** `// HIG-EXEMPT: <reason>`
- **Platform flag:** `--platform <macOS|iOS|iPadOS|visionOS|tvOS|watchOS>` (comma-separated, defaults to all detected platforms)

---

### Rule Catalog

Rules are organized in three tiers by detection confidence and false-positive risk. Each rule is tagged with its applicable platforms.

**Platform legend:** `[mac]` macOS, `[ios]` iOS, `[ipad]` iPadOS, `[vision]` visionOS, `[tv]` tvOS, `[watch]` watchOS, `[all]` all platforms

---

#### Tier 1: Structural Rules (errors in `--strict` mode)

These check for the *presence* of required architectural elements. Low false-positive risk — either the structure exists or it doesn't.

##### Rule `hig.settings-scene` `[mac]`
**HIG basis:** App menu must include Cmd-comma Settings.
**Detection:** In files containing a struct conforming to `App`, check that the `body` property contains a `Settings` scene.
**Auto-fix:** Insert `Settings { Text("Settings") }` after the last scene in the App body.
```swift
// FAIL — no Settings scene
@main struct MyApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// PASS
@main struct MyApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
        Settings { SettingsView() }
    }
}
```

##### Rule `hig.menu-commands` `[mac]` `[ipad]`
**HIG basis:** "Use the menu bar to give people easy access to all the commands they need." iPadOS 16+ exposes the menu bar with hardware keyboards.
**Detection:** App struct body or WindowGroup must include `.commands { }` modifier with at least one `CommandGroup` or `CommandMenu`.
**Auto-fix:** Append `.commands { CommandGroup(replacing: .newItem) { } }` to the WindowGroup.
```swift
// FAIL — no .commands modifier
WindowGroup { ContentView() }

// PASS
WindowGroup { ContentView() }
    .commands {
        CommandGroup(replacing: .newItem) { /* ... */ }
        CommandMenu("Document") { /* ... */ }
    }
```

##### Rule `hig.navigation-pattern` `[mac]` `[ipad]` `[vision]`
**HIG basis:** macOS and iPadOS apps with complex hierarchies should use sidebar + split view, not stack-based navigation. visionOS apps benefit from split views for spatial layout.
**Detection:** Flag `NavigationStack` in files targeting these platforms when the project has multiple navigation destinations. Suggest `NavigationSplitView`.
**Note:** On iOS (iPhone), `NavigationStack` is the correct pattern. This rule does not apply to `[ios]`.
```swift
// WARNING on macOS/iPadOS/visionOS
NavigationStack { /* ... */ }

// PREFERRED
NavigationSplitView {
    Sidebar()
} detail: {
    DetailView()
}
```
**Exemption:** `// HIG-EXEMPT: single-purpose utility window`

##### Rule `hig.window-resizability` `[mac]` `[ipad]` `[vision]`
**HIG basis:** "Make sure that your windows adapt fluidly to different sizes." (macOS: resize/move; iPadOS 18+: windowed mode; visionOS: resize controls)
**Detection:** WindowGroup scenes that use `.windowResizability(.contentSize)` without min/max frame dimensions.

##### Rule `hig.tab-bar-navigation` `[ios]` `[ipad]` `[tv]` `[vision]`
**HIG basis:** "Use a tab bar to support navigation, not to provide actions."
**Detection:** `TabView` where tab content contains only `Button` actions rather than navigation destinations. Also flags `TabView` with `.tabViewStyle(.page)` on non-iOS platforms (page-style tabs are an iOS-specific pattern).

##### Rule `hig.glass-background` `[vision]`
**HIG basis:** "Retain the window's glass background."
**Detection:** WindowGroup or View body that applies `.background()` with an opaque color or material, overriding the system glass. Flag `Color.white`, `Color.black`, or any non-clear opaque Color used as the root background.
```swift
// WARNING — removes glass
WindowGroup {
    ContentView()
        .background(Color.white)
}

// PASS — preserves glass
WindowGroup {
    ContentView()
}
```

---

#### Tier 2: Modifier Rules (warnings)

These check for missing modifiers on interactive SwiftUI views. Moderate false-positive risk — scoped to high-value targets.

##### Rule `hig.toolbar-tooltips` `[mac]` `[ipad]`
**HIG basis:** Users with pointer devices expect hover feedback on toolbar items.
**Detection:** `ToolbarItem` or `ToolbarItemGroup` content that contains `Button` without a `.help()` modifier.
**Auto-fix:** Insert `.help("TODO: describe action")` after the Button.
```swift
// WARNING — no tooltip
ToolbarItem {
    Button(action: addItem) {
        Label("Add", systemImage: "plus")
    }
}

// PASS
ToolbarItem {
    Button(action: addItem) {
        Label("Add", systemImage: "plus")
    }
    .help("Add a new item")
}
```

##### Rule `hig.keyboard-shortcuts` `[mac]` `[ipad]` `[vision]`
**HIG basis:** "Handle keyboard shortcuts to help people accelerate actions." iPadOS and visionOS support hardware keyboards.
**Detection:** `Button` views inside `ToolbarItem` (with `.primaryAction` or `.secondaryAction` placement) or inside `.commands { }` blocks, without `.keyboardShortcut()`.
**Auto-fix:** Insert `.keyboardShortcut("TODO")` after the Button.
```swift
// WARNING — primary toolbar action without shortcut
ToolbarItem(placement: .primaryAction) {
    Button("New Document") { createDoc() }
}

// PASS
ToolbarItem(placement: .primaryAction) {
    Button("New Document") { createDoc() }
        .keyboardShortcut("n")
}
```

##### Rule `hig.context-menus` `[all except watch]`
**HIG basis:** "Support context menus consistently throughout your app." All platforms except watchOS support context menus (long-press on iOS, right-click on macOS, pinch-and-hold on visionOS).
**Detection:** `List` or `ForEach` constructs where the item view body does not include a `.contextMenu` modifier.
**Auto-fix:** Insert `.contextMenu { }` after the item view.
```swift
// WARNING — list items without context menu
List(items) { item in
    ItemRow(item: item)
}

// PASS
List(items) { item in
    ItemRow(item: item)
        .contextMenu {
            Button("Delete", role: .destructive) { delete(item) }
        }
}
```

##### Rule `hig.semantic-colors` `[all]`
**HIG basis:** All platforms support Dark Mode, and macOS desaturates inactive windows. Hardcoded Color literals bypass system vibrancy, Dynamic Type contrast, and accessibility adaptations.
**Detection:** Flag hardcoded `Color` initializers (`Color(.sRGB, ...)`, `Color(red:green:blue:)`, `Color.blue`, `Color.red`, `Color.green`, `Color.orange`, `Color.purple`, `Color.pink`, `Color.yellow`) in View bodies. Suggest semantic alternatives (`.tint`, `.primary`, `.secondary`, `Color("AssetName")`).
**Exempt:** `Color.clear`, `Color.white`, `Color.black`, `Color.accentColor` are not flagged.
**Auto-fix:** Replace `Color.blue` with `.tint` (the most common semantic equivalent).
```swift
// WARNING
Text("Hello").foregroundStyle(Color(red: 0.2, green: 0.5, blue: 0.8))

// PREFERRED
Text("Hello").foregroundStyle(.tint)
```

##### Rule `hig.toolbar-placement` `[mac]` `[ipad]` `[ios]`
**HIG basis:** Toolbar items should use semantic placement for coherent, adaptive layout.
**Detection:** `ToolbarItem` without an explicit `placement:` argument.
**Auto-fix:** Insert `placement: .automatic` as a starting point.
```swift
// WARNING — no placement
ToolbarItem { Button("Action") { } }

// PASS
ToolbarItem(placement: .primaryAction) { Button("Action") { } }
```

##### Rule `hig.inactive-window-state` `[mac]`
**HIG basis:** Key, Main, and Inactive windows must have different appearances.
**Detection:** View structs that use `.listRowBackground()`, `.background()`, or `.foregroundStyle()` with non-semantic colors but never read `@Environment(\.controlActiveState)`. Scoped to views that manage selection (contain `selection` binding or `@State` named `selected*`).

##### Rule `hig.tab-bar-visibility` `[ios]` `[ipad]`
**HIG basis:** "Make sure the tab bar is visible when people navigate to different sections of your app."
**Detection:** `.toolbar(.hidden, for: .tabBar)` applied unconditionally (not inside a sheet or fullScreenCover).
```swift
// WARNING — hiding tab bar outside modal context
NavigationStack {
    DetailView()
        .toolbar(.hidden, for: .tabBar)
}

// OK — hiding tab bar inside a sheet is fine
.sheet(isPresented: $showSheet) {
    SheetView()
        .toolbar(.hidden, for: .tabBar)
}
```

##### Rule `hig.focus-system` `[tv]`
**HIG basis:** "Rely on system-provided focus effects." tvOS focus is fundamental to the interaction model.
**Detection:** Custom `.focusEffect()` modifiers or `UIFocusEffect` subclasses that replace system parallax. Flag `.hoverEffect(.highlight)` or `.hoverEffect(.lift)` overrides on tvOS.

---

#### Tier 3: Completeness Rules (notes/suggestions)

Higher false-positive risk. Checklist items, never errors.

##### Rule `hig.multi-window` `[mac]` `[ipad]` `[vision]`
**HIG basis:** "People typically run several apps at the same time." iPadOS 18+ supports free-form windowing. visionOS apps can display multiple windows in space.
**Detection:** App struct with only one `WindowGroup` and no `openWindow` environment usage anywhere in the project.

##### Rule `hig.drag-drop` `[mac]` `[ipad]` `[ios]` `[vision]`
**HIG basis:** "Move or duplicate selected content by dragging." All pointer/touch platforms support drag-and-drop.
**Detection:** `List` or `ForEach` with `.onDelete` or `.swipeActions` but no `.draggable()` / `.dropDestination()`.

##### Rule `hig.undo-support` `[all except watch]`
**HIG basis:** "Essential to help people remain in control."
**Detection:** View structs with mutation actions (containing `@State` or `@Binding` writes in Button/action closures) that never access `@Environment(\.undoManager)`.

##### Rule `hig.focus-support` `[mac]` `[ipad]` `[tv]` `[vision]`
**HIG basis:** "Support Full Keyboard Access when possible." Essential on tvOS (remote-driven) and macOS (keyboard-driven). Important on iPadOS and visionOS with hardware keyboards.
**Detection:** Custom interactive views (containing `.onTapGesture`) without `.focusable()` modifier.

##### Rule `hig.help-menu` `[mac]`
**HIG basis:** Help menu required at trailing end of menu bar.
**Detection:** App struct with `.commands { }` but no `CommandGroup(replacing: .help)` or `CommandMenu("Help")`.

##### Rule `hig.window-menu` `[mac]`
**HIG basis:** "Provide a Window menu even if your app has only one window."
**Detection:** App struct with `.commands { }` but no Window-related `CommandGroup`.

##### Rule `hig.sidebar-adaptable` `[ipad]`
**HIG basis:** "Prefer a tab bar for navigation" with "the option to convert the tab bar to a sidebar" for complex apps.
**Detection:** `TabView` with more than 5 tabs that doesn't use `.tabViewStyle(.sidebarAdaptable)`.
```swift
// NOTE — many tabs, consider sidebar adaptation
TabView {
    Tab("Home", systemImage: "house") { HomeView() }
    Tab("Search", systemImage: "magnifyingglass") { SearchView() }
    Tab("Library", systemImage: "books.vertical") { LibraryView() }
    Tab("Activity", systemImage: "chart.bar") { ActivityView() }
    Tab("Settings", systemImage: "gear") { SettingsView() }
    Tab("Profile", systemImage: "person") { ProfileView() }
}

// PREFERRED
TabView { /* ... */ }
    .tabViewStyle(.sidebarAdaptable)
```

##### Rule `hig.volume-sizing` `[vision]`
**HIG basis:** "Choose an initial window size that minimizes empty areas." "Choose a minimum and maximum size for each window."
**Detection:** `WindowGroup` with `.windowStyle(.volumetric)` but no `.defaultSize()` modifier.

##### Rule `hig.ornament-usage` `[vision]`
**HIG basis:** "Consider offering high-value content in an ornament" for volumes.
**Detection:** `WindowGroup` with `.windowStyle(.volumetric)` that has toolbar items but no `.ornament()` modifier. Note-level suggestion only.

---

### Platform Applicability Matrix

| Rule | mac | iOS | iPad | vision | tv | watch |
|------|:---:|:---:|:----:|:------:|:--:|:-----:|
| **Tier 1** | | | | | | |
| `hig.settings-scene` | x | | | | | |
| `hig.menu-commands` | x | | x | | | |
| `hig.navigation-pattern` | x | | x | x | | |
| `hig.window-resizability` | x | | x | x | | |
| `hig.tab-bar-navigation` | | x | x | x | x | |
| `hig.glass-background` | | | | x | | |
| **Tier 2** | | | | | | |
| `hig.toolbar-tooltips` | x | | x | | | |
| `hig.keyboard-shortcuts` | x | | x | x | | |
| `hig.context-menus` | x | x | x | x | x | |
| `hig.semantic-colors` | x | x | x | x | x | x |
| `hig.toolbar-placement` | x | x | x | | | |
| `hig.inactive-window-state` | x | | | | | |
| `hig.tab-bar-visibility` | | x | x | | | |
| `hig.focus-system` | | | | | x | |
| **Tier 3** | | | | | | |
| `hig.multi-window` | x | | x | x | | |
| `hig.drag-drop` | x | x | x | x | | |
| `hig.undo-support` | x | x | x | x | x | |
| `hig.focus-support` | x | | x | x | x | |
| `hig.help-menu` | x | | | | | |
| `hig.window-menu` | x | | | | | |
| `hig.sidebar-adaptable` | | | x | | | |
| `hig.volume-sizing` | | | | x | | |
| `hig.ornament-usage` | | | | x | | |

**Total: 23 rules** (6 Tier 1, 8 Tier 2, 9 Tier 3)

---

### Severity Model

| Tier | Default Severity | `--strict` Severity | Rationale |
|------|-----------------|---------------------|-----------|
| 1 (Structural) | warning | error | Missing architecture is a clear gap |
| 2 (Modifier) | note | warning | Contextual — not every element needs every modifier |
| 3 (Completeness) | note | note | Checklist items, never errors |

### Exemption System

Developers can suppress individual rules with inline comments:

```swift
// HIG-EXEMPT: single-purpose utility, no sidebar needed
NavigationStack { UtilityView() }
```

Or in configuration:
```yaml
hig-auditor:
  platforms: [macOS, iPadOS]          # only check these platforms
  exclude-rules:
    - hig.navigation-pattern          # this is a menubar-only utility
    - hig.multi-window
  exclude-paths:
    - Sources/Internal/Debug/          # debug-only views
```

---

## Architecture

### Module: `HIGAuditor`

```
Sources/HIGAuditor/
├── HIGAuditor.swift                # QualityChecker + FixableChecker implementation
├── PlatformDetector.swift          # Determines target platforms from Package.swift / #if os()
├── AppStructureVisitor.swift       # Tier 1: walks @main App struct for scenes, commands
├── ViewModifierVisitor.swift       # Tier 2: checks modifier chains on interactive views
├── CompletenessVisitor.swift       # Tier 3: project-wide aggregation checks
├── ModifierChainWalker.swift       # Shared utility: walks SwiftUI modifier chains to boundaries
├── HIGRules.swift                  # Rule ID constants, messages, platform tags, fix templates
└── HIGFixer.swift                  # FixableChecker: auto-fix implementations
```

**Dependencies:** `QualityGateCore`, `SwiftSyntax`, `SwiftParser`

### Detection Strategy

1. **Phase 1 — Platform Detection:** Parse `Package.swift` for `.macOS()`, `.iOS()`, etc. platform declarations. Also check individual files for `#if os(macOS)` / `#if os(iOS)` conditionals. Build a set of active platforms for the project.

2. **Phase 2 — File Classification:** Scan each `.swift` file's imports and struct conformances. Files that `import SwiftUI` and contain `App`, `Scene`, or `View` conformances are candidates. Utility files importing SwiftUI for types only are skipped.

3. **Phase 3 — App Entry Point Analysis (Tier 1):** Find the `@main` struct conforming to `App`. Walk its `body` computed property to catalog scenes, commands, and modifiers. Filter rules by detected platforms.

4. **Phase 4 — View Analysis (Tier 2):** For each `View`-conforming struct, walk its `body` to check modifier chains on interactive elements. Walk up to the nearest container boundary (`ToolbarItem`, `VStack`, `HStack`, `ZStack`, `Group`, `ForEach`, `List`) when checking for modifiers.

5. **Phase 5 — Project-Wide Analysis (Tier 3):** Aggregate findings across all files. Check for project-level patterns (multi-window, undo manager usage, drag-drop).

### Key SwiftSyntax Patterns

**Modifier chain walking:** SwiftUI modifier chains are nested `FunctionCallExprSyntax` nodes. To check if a `Button` has `.help()`, walk up the parent chain looking for a `MemberAccessExprSyntax` where `declName.baseName.text == "help"`. Stop at the nearest container boundary.

**Scene enumeration:** In the App struct's `body`, each expression maps to a scene. Check for `DeclReferenceExprSyntax` nodes named `Settings`, `WindowGroup`, `DocumentGroup`, `MenuBarExtra`.

**Attribute detection:** `@main` is an `AttributeSyntax` on the struct declaration. `@Environment` property wrappers are detected via `CustomAttributeSyntax` on variable declarations.

**Platform conditionals:** `#if os(macOS)` blocks are `IfConfigDeclSyntax` nodes. The condition contains `FunctionCallExprSyntax` with `os` as the function name and the platform as the argument.

---

## Auto-Fix Support (FixableChecker)

The auditor implements `FixableChecker` from Phase 1. Auto-fixes are conservative — they insert TODO-marked scaffolding rather than guessing at correct content.

| Rule | Fix Action |
|------|-----------|
| `hig.settings-scene` | Insert `Settings { Text("TODO: Settings") }` after last scene |
| `hig.menu-commands` | Append `.commands { CommandGroup(replacing: .newItem) { /* TODO */ } }` |
| `hig.toolbar-tooltips` | Insert `.help("TODO: describe action")` after Button |
| `hig.keyboard-shortcuts` | Insert `.keyboardShortcut("TODO")` after Button |
| `hig.context-menus` | Insert `.contextMenu { /* TODO */ }` after item view |
| `hig.toolbar-placement` | Insert `placement: .automatic` in ToolbarItem initializer |
| `hig.semantic-colors` | Replace `Color.blue` → `.tint`, `Color.red` → `.red` (asset) |

Fixes are applied via `FileModification` and the existing `FixResult` pipeline. Each fix includes a backup path.

---

## Implementation Plan

### Phase 1: Foundation + Structural + Auto-Fix
**Scope:** Module scaffold, platform detection, 6 Tier 1 rules, FixableChecker for applicable rules
**Rules:** `settings-scene`, `menu-commands`, `navigation-pattern`, `window-resizability`, `tab-bar-navigation`, `glass-background`
**Effort:** ~3 sessions
**Deliverables:**
- `HIGAuditor` module with `QualityChecker` + `FixableChecker` conformance
- `PlatformDetector` for Package.swift parsing and `#if os()` detection
- `AppStructureVisitor` with Tier 1 checks
- `HIGFixer` with auto-fixes for `settings-scene`, `menu-commands`
- Test target with SwiftUI source fixtures (pass/fail/fix cases per rule)
- Registration in `QualityGateCLI`
- Exemption support (`// HIG-EXEMPT:`)
- `--platform` CLI flag

### Phase 2: Modifier Enforcement
**Scope:** 8 Tier 2 rules with auto-fixes
**Rules:** `toolbar-tooltips`, `keyboard-shortcuts`, `context-menus`, `semantic-colors`, `toolbar-placement`, `inactive-window-state`, `tab-bar-visibility`, `focus-system`
**Effort:** ~3 sessions
**Deliverables:**
- `ViewModifierVisitor` with modifier chain analysis
- `ModifierChainWalker` utility (reusable for future SwiftUI checks)
- Auto-fixes for `toolbar-tooltips`, `keyboard-shortcuts`, `context-menus`, `toolbar-placement`, `semantic-colors`
- Extended test fixtures

### Phase 3: Completeness Checks
**Scope:** 9 Tier 3 rules
**Rules:** `multi-window`, `drag-drop`, `undo-support`, `focus-support`, `help-menu`, `window-menu`, `sidebar-adaptable`, `volume-sizing`, `ornament-usage`
**Effort:** ~2 sessions
**Deliverables:**
- `CompletenessVisitor` with project-wide aggregation
- Configuration schema for rule exclusions and platform overrides

### Phase 4: Liquid Glass / OS 27 Update
**Scope:** TBD based on OS 27 announcements
**Likely additions:**
- Updated material/vibrancy rules for Liquid Glass
- New sidebar guidance (sidebars now float in Liquid Glass layer on iOS/iPadOS/macOS)
- Tab bar Liquid Glass compliance (iOS 26+ tab bars use Liquid Glass)
- New `.glassBackgroundEffect()` or equivalent modifiers
**Notes:** Current rules are additive — OS 27 may introduce new checks but shouldn't invalidate existing ones. The `hig.semantic-colors`, `hig.inactive-window-state`, and `hig.glass-background` rules are the most likely to need updates.

---

## Example Output

```
$ quality-gate --check hig-auditor --strict --platform macOS,iPadOS

HIG Auditor
═══════════

Platforms: macOS, iPadOS (detected from Package.swift)

ERRORS
  Sources/MyApp/MyApp.swift:5:8
    hig.settings-scene [macOS]: App struct missing Settings scene.
    → Add: Settings { SettingsView() } to your App body.
    ⚡ Auto-fixable: run with --fix

  Sources/MyApp/MyApp.swift:5:8
    hig.menu-commands [macOS, iPadOS]: App struct has no .commands { } modifier.
    → Add .commands { } with CommandGroup or CommandMenu to your WindowGroup.
    ⚡ Auto-fixable: run with --fix

WARNINGS
  Sources/MyApp/ContentView.swift:12:5
    hig.navigation-pattern [macOS, iPadOS]: NavigationStack used — consider
    NavigationSplitView for sidebar-based navigation on larger displays.

  Sources/MyApp/Toolbar.swift:8:9
    hig.toolbar-tooltips [macOS, iPadOS]: Button in ToolbarItem missing
    .help() tooltip for pointer hover feedback.
    ⚡ Auto-fixable: run with --fix

  Sources/MyApp/ListView.swift:22:9
    hig.context-menus [macOS, iPadOS]: List items missing .contextMenu modifier.
    → Add .contextMenu { } for right-click / long-press actions.
    ⚡ Auto-fixable: run with --fix

  Sources/MyApp/DetailView.swift:15:13
    hig.semantic-colors [all]: Hardcoded Color(red:green:blue:) in View body.
    → Use semantic colors (.tint, .secondary) for Dark Mode and
      inactive window support.
    ⚡ Auto-fixable: run with --fix

NOTES
  Sources/MyApp/MyApp.swift:5:8
    hig.multi-window [macOS, iPadOS]: App has one WindowGroup and no
    openWindow usage. Consider multi-window support.

  Sources/MyApp/EditorView.swift:1:1
    hig.undo-support [macOS, iPadOS]: View with @State mutations but no
    undoManager access. Consider UndoManager for reversible actions.

──────────────────────────────────
Result: FAILED (2 errors, 4 warnings, 2 notes)
       6 auto-fixable — run with --fix
```

---

## Testing Strategy

Each rule gets a pair of tests (positive/negative) with minimal SwiftUI source fixtures, plus a fix-verification test where applicable:

```swift
func testSettingsSceneMissing() async throws {
    let source = """
    import SwiftUI
    @main struct TestApp: App {
        var body: some Scene {
            WindowGroup { Text("Hello") }
        }
    }
    """
    let result = try await auditor.auditSource(source, fileName: "TestApp.swift",
                                                configuration: macOSConfig)
    XCTAssertEqual(result.status, .failed)
    XCTAssertTrue(result.diagnostics.contains { $0.ruleId == "hig.settings-scene" })
}

func testSettingsScenePresent() async throws {
    let source = """
    import SwiftUI
    @main struct TestApp: App {
        var body: some Scene {
            WindowGroup { Text("Hello") }
            Settings { Text("Settings") }
        }
    }
    """
    let result = try await auditor.auditSource(source, fileName: "TestApp.swift",
                                                configuration: macOSConfig)
    XCTAssertFalse(result.diagnostics.contains { $0.ruleId == "hig.settings-scene" })
}

func testSettingsSceneNotFlaggedOnIOS() async throws {
    let source = """
    import SwiftUI
    @main struct TestApp: App {
        var body: some Scene {
            WindowGroup { Text("Hello") }
        }
    }
    """
    let result = try await auditor.auditSource(source, fileName: "TestApp.swift",
                                                configuration: iOSOnlyConfig)
    XCTAssertFalse(result.diagnostics.contains { $0.ruleId == "hig.settings-scene" })
}

func testSettingsSceneAutoFix() async throws {
    let source = """
    import SwiftUI
    @main struct TestApp: App {
        var body: some Scene {
            WindowGroup { Text("Hello") }
        }
    }
    """
    let diagnostics = [Diagnostic(severity: .error, message: "",
                                   filePath: "TestApp.swift", lineNumber: 3,
                                   ruleId: "hig.settings-scene")]
    let fixResult = try await auditor.fix(diagnostics: diagnostics,
                                           configuration: macOSConfig)
    XCTAssertEqual(fixResult.modifications.count, 1)
    XCTAssertTrue(fixResult.unfixed.isEmpty)
}
```

Tests use string literals as source fixtures — no SwiftUI framework needed at test time since we only do AST analysis. Platform-conditional tests verify rules don't fire on wrong platforms.

---

## Open Questions (Resolved)

1. **Scope detection:** ~~How do we know a file targets macOS?~~ **Resolved:** Multi-strategy approach. Parse `Package.swift` for platform declarations, check `#if os()` conditionals, support `--platform` CLI override. Default to all platforms found in Package.swift.

2. **SwiftUI file detection heuristic:** Only check files containing `View`, `App`, or `Scene` conformances. Utility files importing SwiftUI for type references are skipped.

3. **Modifier chain depth:** Walk up to the nearest container boundary (`ToolbarItem`, `VStack`, `HStack`, `ZStack`, `Group`, `ForEach`, `List`, `Form`, `Section`). A `.help()` on a `VStack` inside a `ToolbarItem` still counts as covering the Button inside.

4. **Liquid Glass / OS 27:** Noted — Phase 4 reserved. Current rules designed to be additive.

## Open Questions (Remaining)

5. **Cross-file modifier tracking:** If a custom view `MyButton` wraps `Button` and always adds `.help()`, we'd false-positive on it. Do we support a `// HIG-PROVIDES: help` annotation on wrapper views? Or is `// HIG-EXEMPT:` sufficient for v1?

6. **Xcode project support:** `PlatformDetector` currently targets SPM (`Package.swift`). Should we also parse `.xcodeproj` / `.xcworkspace` for platform targets? Proposal: SPM-only for v1, Xcode support as a follow-up.

7. **watchOS depth:** The HIG has minimal SwiftUI-specific guidance for watchOS beyond layout. Currently only `hig.semantic-colors` applies. Should we add watchOS-specific rules (e.g., Digital Crown support, complication guidance) or keep watchOS minimal?
