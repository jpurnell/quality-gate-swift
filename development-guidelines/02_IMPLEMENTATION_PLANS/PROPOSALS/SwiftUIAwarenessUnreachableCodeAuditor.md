# SwiftUI Awareness for UnreachableCodeAuditor

**Date:** 2026-05-25
**Context:** The UnreachableCodeAuditor's cross-module pass uses BFS reachability from entry-point roots through an IndexStoreDB call graph. It has no understanding of SwiftUI's runtime model — property wrapper synthesis, environment injection, view composition, and declarative rendering. This causes **~120 false positives** on a typical SwiftUI app (WineTaster 4: 143 errors, ~85% false positive rate).

**Motivation:** SwiftUI is the dominant UI framework for Apple platforms. Any quality gate that produces triple-digit false positives on a standard SwiftUI app is unusable for its primary audience. The auditor must understand SwiftUI's implicit entry points the same way it already understands `@objc`, `@main`, protocol witnesses, and `CodingKey` enums.

**Status:** Implemented

---

## The Problem, Concretely

Running `quality-gate --check unreachable --strict` on WineTaster 4 (a macOS SwiftUI app) produces 143 errors. Examining them reveals:

| False Positive Category | Count | Example |
|------------------------|-------|---------|
| `@EnvironmentObject` properties | ~25 | `@EnvironmentObject var tasting: Tasting` — injected by SwiftUI, used in `body` |
| `@State` / `@Binding` properties | ~15 | `@State private var path = NavigationPath()` — read via `$path` binding |
| `@Environment` key paths | ~12 | `@Environment(\.horizontalSizeClass) var horizontalSizeClass` — used in conditionals |
| `@Published` in ObservableObject | ~19 | `@Published var breakpointMethod` — bound by SwiftUI subscribers |
| `@StateObject` properties | ~6 | `@StateObject var cloudQuery: CloudQuery` — lifecycle-managed |
| `let` / computed properties in View structs | ~10 | `let formatter = numberFormatter(digits: 4)` — used in `body` |
| View struct members (stored props, methods) | ~20 | `var gradient: Gradient` — consumed by Chart modifiers |
| Combine `AnyCancellable` subscriptions | ~6 | `private var subscriptions = Set<AnyCancellable>()` — held for lifetime |
| Static constants in utility structs | ~10 | `Strings.Input.tastingNumber` — referenced cross-module |
| **Genuinely dead code** | **~20** | `Strings.Input.*` constants from legacy CLI, unused HTML helpers |

The auditor correctly identifies ~20 genuinely dead symbols but buries them in ~120 false positives, making the check impossible to act on.

### Root Cause

The auditor's BFS reachability walk starts from these root categories (IndexStorePass Pass 2):

1. `@main` types and their members
2. Public/open API in library targets
3. `@objc` / `@IBAction` / `@_cdecl` annotated symbols
4. Protocol witnesses (via WellKnownWitnesses allow-list)
5. Initializers
6. `CodingKey` enum cases
7. Test target symbols
8. `// LIVE:` exempted symbols

**What's missing:** SwiftUI's runtime creates implicit entry points that the index store doesn't record:

- **Property wrappers synthesize storage and accessors** — `@State var x` becomes `_x: State<T>` with a projected `$x` binding. The index records the synthesized accessor but doesn't show SwiftUI's runtime reading the wrapped value.
- **`body` is a protocol witness** — already handled via WellKnownWitnesses, but members *used only within body* still appear unreachable because the auditor can't trace through SwiftUI's rendering pipeline.
- **Environment injection is invisible** — `@EnvironmentObject var foo: Foo` is populated by SwiftUI's environment propagation, not by any source-level assignment. No call-graph edge exists.
- **View composition is declarative** — `SomeView()` in a `body` expression instantiates a type, but the auditor sees the type definition as unreachable if no *explicit* call site exists outside view bodies.

### What Existing Auditors Can't Catch

| Gap | Current Behavior | Why It Misses |
|-----|-----------------|---------------|
| `@State`/`@Binding` usage | Flagged as unreachable | Projected binding `$var` is compiler-synthesized, not in index |
| `@EnvironmentObject` | Flagged as unreachable | Injected at runtime by SwiftUI, no source-level assignment |
| `@Environment` key paths | Flagged as unreachable | Framework provides value, auditor sees no write |
| `@Published` in ObservableObject | Flagged as unreachable | Combine subscriber chain not in call graph |
| View struct members | Flagged as unreachable | Used in `body` which *is* reachable, but members aren't traced through it |
| `@StateObject` lifecycle | Flagged as unreachable | SwiftUI manages lifecycle, no explicit creation path |

---

## Proposed Architecture

### Design Principle: Treat SwiftUI Property Wrappers as Implicit Entry Points

The same way the auditor already treats `@objc` as "reachable from Objective-C runtime" and `CodingKey` cases as "reachable from Codable synthesis," we treat SwiftUI property wrappers as "reachable from SwiftUI's rendering pipeline."

This is a **conservative allow-list approach** — we mark known-safe patterns as roots rather than attempting to model SwiftUI's full rendering graph. This matches the auditor's existing philosophy (WellKnownWitnesses, `@objc`, `CodingKey`).

### Strategy: Three Layers of SwiftUI Awareness

#### Layer 1: SwiftUI Property Wrapper Recognition (Liveness.swift)

Add a new boolean flag `isSwiftUIWired` to `DeclFact`. A declaration gets this flag if it uses any of these property wrappers:

**State & Binding family:**
- `@State`, `@Binding`, `@StateObject`, `@ObservedObject`

**Environment family:**
- `@Environment`, `@EnvironmentObject`

**Observable family:**
- `@Published` (on properties inside types conforming to `ObservableObject`)

**AppStorage & SceneStorage:**
- `@AppStorage`, `@SceneStorage`

**Other SwiftUI wrappers:**
- `@FetchRequest`, `@SectionedFetchRequest`, `@Query` (SwiftData)
- `@FocusState`, `@FocusedValue`, `@FocusedBinding`
- `@GestureState`
- `@Namespace`
- `@ScaledMetric`
- `@UIApplicationDelegateAdaptor`, `@NSApplicationDelegateAdaptor`

**Implementation:** In `DeclFactVisitor.visit(_ node: VariableDeclSyntax)`, check for these attribute names on the variable declaration. If any match, set `isSwiftUIWired = true`.

#### Layer 2: View-Type Member Promotion (Liveness.swift)

Add a depth counter `swiftUIViewTypeDepth` analogous to the existing `mainTypeDepth` and `publicProtocolDepth`. When the visitor enters a struct/class that:
1. Has a `body` property (heuristic: contains a `var body` binding), OR
2. Conforms to `View`, `Scene`, `App`, `Widget`, `Commands`, `WidgetBundle`, `PreviewProvider`, `LibraryContentProvider`

...all members within that type get a new flag `isSwiftUIViewMember = true`.

**Why struct-level, not individual members?** SwiftUI views are value types whose *entire* stored state is read by the framework during rendering. Any stored property could be referenced in `body` (or in a helper called from `body`). Marking the whole type as "SwiftUI-managed" is both simpler and more correct than trying to trace individual member usage through complex view expressions.

**Conformance detection heuristic:** Since DeclFactVisitor works on syntax (not types), we use a two-pronged heuristic:
- **Inheritance clause check:** Look for `View`, `Scene`, `App`, `Widget`, `Commands` etc. in the type's inheritance clause
- **`body` property check:** Any struct with a computed `var body` that returns `some View` / `some Scene` / `some WidgetConfiguration` is treated as a SwiftUI type

This matches how the auditor already detects `CodingKey` conformance syntactically.

#### Layer 3: Root Seeding in IndexStorePass (IndexStorePass.swift)

In Pass 2 (root identification), add two new root conditions after the existing `isCodingKey` check:

```
// SwiftUI property wrapper — reachable from SwiftUI's rendering pipeline
if fact.isSwiftUIWired { roots.insert(rec.usr) }

// Member of a SwiftUI View/Scene/App type — rendered by framework
if fact.isSwiftUIViewMember { roots.insert(rec.usr) }
```

This means:
- Every `@State`, `@EnvironmentObject`, `@Published`, etc. property is a root
- Every member of a View struct (stored properties, methods, computed properties) is a root
- The BFS walk then propagates from these roots, keeping alive anything they reference

### Modified Files

| File | Change |
|------|--------|
| `Sources/UnreachableCodeAuditor/Liveness.swift` | Add `isSwiftUIWired` and `isSwiftUIViewMember` to `DeclFact`; add `swiftUIViewTypeDepth` counter; detect property wrapper attributes and View-type conformance in visitor |
| `Sources/UnreachableCodeAuditor/IndexStorePass.swift` | Add two root-seeding conditions for new fact flags |
| `Tests/UnreachableCodeAuditorTests/Fixtures/CrossModuleFixture/Sources/FixtureLib/SwiftUIPatterns.swift` | New fixture file with SwiftUI patterns |
| `Tests/UnreachableCodeAuditorTests/Fixtures/CrossModuleFixture/Sources/FixtureExe/SwiftUIExePatterns.swift` | New fixture file for executable-target SwiftUI patterns |
| `Tests/UnreachableCodeAuditorTests/SwiftUIAwarenessTests.swift` | New test file for SwiftUI-specific false positive prevention |

### What This Does NOT Change

- **Well-known witnesses** — `body` is already handled; no changes needed to `WellKnownWitnesses+Curated.swift` or the generated file
- **Syntactic pass** — The single-file unused-private check is unaffected (it only looks at private symbols within one file)
- **Non-SwiftUI projects** — The new flags default to `false`; projects without SwiftUI property wrappers see identical behavior
- **Genuinely dead code** — A `@State` property in a View struct that is truly never read in `body` or any method would still be marked as a root (conservative). This is acceptable — the same trade-off exists for `@objc` (we don't verify ObjC actually calls it)

---

## API Surface

No new public API. All changes are internal to the `UnreachableCodeAuditor` module.

### Internal Changes

```swift
// Liveness.swift — DeclFact additions
struct DeclFact {
    // ... existing fields ...
    var isSwiftUIWired: Bool      // @State, @Binding, @EnvironmentObject, etc.
    var isSwiftUIViewMember: Bool  // member of a View/Scene/App struct
}

// Liveness.swift — DeclFactVisitor additions
private static let swiftUIPropertyWrappers: Set<String> = [
    "State", "Binding", "StateObject", "ObservedObject",
    "Environment", "EnvironmentObject",
    "Published",
    "AppStorage", "SceneStorage",
    "FetchRequest", "SectionedFetchRequest", "Query",
    "FocusState", "FocusedValue", "FocusedBinding",
    "GestureState", "Namespace", "ScaledMetric",
    "UIApplicationDelegateAdaptor", "NSApplicationDelegateAdaptor"
]

private static let swiftUITypeProtocols: Set<String> = [
    "View", "Scene", "App", "Widget", "Commands",
    "WidgetBundle", "PreviewProvider", "LibraryContentProvider"
]
```

---

## Constraints & Compliance

- **Concurrency:** `DeclFact` is a value type (already `Sendable`); adding two `Bool` fields doesn't change this
- **Swift 6 compliance:** No new concurrency concerns — all analysis is synchronous within the auditor
- **No new dependencies:** Uses only SwiftSyntax (already a dependency)
- **Backward compatibility:** New flags default to `false`; existing behavior unchanged for non-SwiftUI code
- **Conservative over aggressive:** We accept some false negatives (genuinely dead `@State` properties won't be caught) to eliminate false positives. This matches the auditor's existing philosophy — the `@objc` root rule has the same trade-off

---

## Dependencies

**Internal:**
- `Liveness.swift` — DeclFact struct and DeclFactVisitor (primary modification target)
- `IndexStorePass.swift` — Root seeding logic (two-line addition)

**External:**
- None. SwiftSyntax already provides all the AST nodes needed

---

## Test Strategy

### Fixture Design

Add SwiftUI patterns to the existing `CrossModuleFixture`:

**`FixtureLib/SwiftUIPatterns.swift`** — Contains:
- A `View` struct with `@State`, `@Binding`, `@Environment`, `@EnvironmentObject` properties
- An `ObservableObject` class with `@Published` properties
- A View struct with stored `let` properties used only in `body`
- A View struct with helper methods called only from `body`
- A genuinely dead `@State` property (to verify we accept this as a known false negative)

**`FixtureExe/SwiftUIExePatterns.swift`** — Contains:
- An `@main` App struct with `@StateObject` properties
- A `Settings` scene usage
- A `WindowGroup` with injected environment objects

### Test Cases

| Test | Assertion | Pattern |
|------|-----------|---------|
| `keepsStateProperty` | NOT flagged | `@State private var count = 0` in View |
| `keepsBindingProperty` | NOT flagged | `@Binding var isPresented: Bool` in View |
| `keepsEnvironmentObjectProperty` | NOT flagged | `@EnvironmentObject var model: Model` in View |
| `keepsEnvironmentProperty` | NOT flagged | `@Environment(\.dismiss) var dismiss` in View |
| `keepsPublishedProperty` | NOT flagged | `@Published var name: String` in ObservableObject |
| `keepsStateObjectProperty` | NOT flagged | `@StateObject var vm = ViewModel()` in View |
| `keepsViewStoredProperty` | NOT flagged | `let formatter = NumberFormatter()` in View |
| `keepsViewHelperMethod` | NOT flagged | `private func formatValue()` in View |
| `keepsAppStorageProperty` | NOT flagged | `@AppStorage("key") var pref = true` in View |
| `stillFlagsDeadInternalFunction` | Flagged | `func deadFunc()` not in any View type |
| `stillFlagsDeadPrivateInNonView` | Flagged | `private func unused()` in non-View struct |

### Validation Against WineTaster 4

After implementation, run `quality-gate --check unreachable --strict --continue-on-failure --verbose` against WineTaster 4. Expected outcome:
- Error count drops from 143 to ~20 (the genuinely dead code)
- All remaining errors are actionable (dead `Strings.Input.*` constants, unused HTML helpers, etc.)

---

## Open Questions (Resolved)

1. **Should `@Published` require ObservableObject context?** **Decision: No — flag unconditionally.** These types should migrate to `@Observable` anyway; a `--fix` mode migration could be a future enhancement.

2. **Should View member promotion extend to extensions?** **Decision: Not in v1.** Extensions require type-resolution beyond syntactic analysis. Accepted limitation — revisit if real-world false positives appear from extension-defined View helpers.

3. **`@Observable` macro (iOS 17+):** **Decision: No additional handling needed.** The existing `looksMacroGenerated()` filter covers synthesized symbols. Add a fixture to verify.

---

## Implementation Sequence

Following TDD workflow:

1. **RED:** Write `SwiftUIAwarenessTests.swift` with all test cases — they will fail because the auditor currently flags SwiftUI patterns
2. **GREEN:** 
   a. Add `isSwiftUIWired` and `isSwiftUIViewMember` to `DeclFact` in `Liveness.swift`
   b. Add property-wrapper detection and View-type detection to `DeclFactVisitor`
   c. Add two root-seeding lines to `IndexStorePass.swift`
3. **REFACTOR:** Extract the property-wrapper name set and View-protocol name set as static constants
4. **VERIFY:** Run against WineTaster 4 and confirm error count drops to ~20

---

## Documentation Strategy

**Documentation Type:** API Docs Only (internal module, no public API change)

**Complexity Threshold Check:**
- Does it combine 3+ APIs? No
- Does explanation require 50+ lines? No
- Does it need theory/background context? No

Update the module-level DocC comment in `UnreachableCodeAuditor.swift` to mention SwiftUI awareness as a supported feature.

---

## Related Documents

- [Master Plan](../00_CORE_RULES/00_MASTER_PLAN.md) — UnreachableCodeAuditor is Phase 2 complete; this is a Phase 4 polish enhancement
- [HIGAuditor Proposal](HIGAuditor.md) — Related SwiftUI awareness work for a different auditor
- [Coding Rules](../00_CORE_RULES/01_CODING_RULES.md) — Implementation constraints
- [Test-Driven Development](../00_CORE_RULES/09_TEST_DRIVEN_DEVELOPMENT.md) — TDD workflow for implementation
