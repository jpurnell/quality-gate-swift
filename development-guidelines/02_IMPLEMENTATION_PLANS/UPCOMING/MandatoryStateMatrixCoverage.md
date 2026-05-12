# Design Proposal: Mandatory State-Matrix Coverage for UI Elements

## 1. Objective

**Objective:** Establish a mandatory testing rule that every SwiftUI view must have a documented state matrix and corresponding view model tests covering all states before being marked "complete." This is a process and guidelines change, not a library addition. Zero external dependencies.

**Problem Statement:** The verification gap between "compiles" and "works" is most acute in UI code because views have multiple visual states driven by combinations of properties. A view can compile, pass type-checking, and even render its default state correctly while being broken in error, loading, or empty states. Without a systematic enumeration of states, testers (human or AI) only verify the happy path.

**Real failures this would have caught:**
- Coherence ring missing in specific app states (biofeedback app)
- Stop button rendered off-screen in recording state
- Volume slider non-functional due to immutable state binding
- TimelineView not updating when `@State` changed

All of these were single-state failures: the default/idle state looked fine, but a specific combination of state values produced a broken UI.

**Approach:** Test the view model, not the view hierarchy. View models contain all state logic, transitions, and computed properties. By exhaustively testing the view model against the state matrix, we catch the bugs that matter (wrong state, wrong transition, missing condition) without depending on third-party libraries that track SwiftUI's internal implementation. The view itself becomes a thin, declarative mapping from view model state to UI — simple enough to verify by inspection.

## 2. Proposed Architecture

**No new code or dependencies.** This is a guidelines addition to the development-guidelines template.

**Modified Files:**
- `00_CORE_RULES/12_UI_TESTING.md` (new — core rules for UI testing)
- `00_CORE_RULES/10_APPLICATION_TESTING_PATTERNS.md` — update testing pyramid to include view-level testing
- `04_IMPLEMENTATION_CHECKLISTS/TEMPLATE.md` — add state-matrix step to the checklist

## 3. API Surface

### The State Matrix

For every view, enumerate a state matrix before writing tests. The matrix is a table of every meaningful combination of the view's state variables and the expected visual outcome.

**Template:**

```markdown
## State Matrix: <ViewName>

| State | Properties | Expected Behavior |
|-------|-----------|-------------------|
| Idle | isRecording=false, error=nil, data=[] | Shows "Start" button, empty data placeholder |
| Recording | isRecording=true, error=nil, data=streaming | Shows "Stop" button, live data display, animation active |
| Error | isRecording=false, error!=nil, data=[] | Shows error banner, "Retry" button, no data display |
| Loaded | isRecording=false, error=nil, data=populated | Shows data visualization, "Start" button, export option |
| Loading | isLoading=true | Shows spinner, all interactive elements disabled |
```

### State Matrix Rules

1. **Every `@State`, `@Binding`, `@Published`, and `@Environment` property that affects rendering must appear in at least one matrix column.**

2. **Minimum states to cover:**

   | State Category | Required? | Description |
   |---------------|-----------|-------------|
   | **Idle/Default** | Always | Initial state on first render |
   | **Active/Primary** | Always | Primary interactive state |
   | **Loading** | If async | While waiting for data |
   | **Empty** | If data-driven | No data available |
   | **Error** | If fallible | Error condition displayed |
   | **Disabled** | If conditional | Interaction disabled |
   | **Edge** | If bounded | Boundary values (max items, long text, zero) |

3. **State transitions must be tested, not just static states.** If `startRecording()` should transition from `.idle` to `.recording`, test that the method produces the expected state change.

4. **The state matrix must be written BEFORE implementation** (during the Design Proposal phase) and updated if the implementation reveals new states.

### Combinatorial Coverage Strategy

| View complexity | Strategy |
|----------------|----------|
| **≤ 3 state dimensions** | Full cross-product (exhaustive) |
| **> 3 state dimensions** | Refactor the view — this is a complexity signal |
| **Always** | Every enum case and boolean value appears in at least one test |
| **Always** | "Impossible" state combinations verified not to crash |

A view needing more than 3 state dimensions is too complex. Decompose it into smaller views, each testable with full cross-product coverage.

### View Model Test Pattern

```swift
import Testing
@testable import MyApp

@Suite("RecordingViewModel State Matrix")
struct RecordingViewModelStateMatrixTests {

    // MARK: - State Matrix
    //
    // | State     | Properties                                    | Expected Behavior                       |
    // |-----------|-----------------------------------------------|-----------------------------------------|
    // | Idle      | state=.idle, error=nil, data=[]               | Can start recording                     |
    // | Recording | state=.recording, error=nil, startTime!=nil   | Can stop recording, timer incrementing  |
    // | Error     | state=.idle, error!=nil                       | Shows error message, can retry          |
    // | Loaded    | state=.idle, error=nil, data=populated        | Can export, can start new recording     |

    // MARK: - Idle State

    @Test("initial state is idle")
    func initialStateIsIdle() {
        let vm = RecordingViewModel()

        #expect(vm.state == .idle)
        #expect(vm.error == nil)
        #expect(vm.data.isEmpty)
        #expect(vm.canStartRecording)
    }

    // MARK: - State Transitions

    @Test("start recording transitions from idle to recording")
    func startTransitionsToRecording() async {
        let vm = RecordingViewModel()

        await vm.startRecording()

        #expect(vm.state == .recording)
        #expect(vm.startTime != nil)
        #expect(!vm.canStartRecording)
    }

    @Test("stop recording transitions from recording to loaded")
    func stopTransitionsToLoaded() async {
        let vm = RecordingViewModel()
        await vm.startRecording()

        await vm.stopRecording()

        #expect(vm.state == .idle)
        #expect(!vm.data.isEmpty)
    }

    @Test("error during recording transitions to error state")
    func errorDuringRecording() async {
        let vm = RecordingViewModel()
        await vm.startRecording()

        vm.handleError(AppError.connectionFailed)

        #expect(vm.state == .idle)
        #expect(vm.errorMessage == "Connection failed")
        #expect(vm.canStartRecording)
    }

    // MARK: - Computed Properties Per State

    @Test("computed properties correct per state",
          arguments: [
            (state: ViewState.idle,      canStart: true,  canStop: false, canExport: false),
            (state: ViewState.recording, canStart: false, canStop: true,  canExport: false),
            (state: ViewState.loaded,    canStart: true,  canStop: false, canExport: true),
          ])
    func computedPropertiesPerState(
        state: ViewState,
        canStart: Bool,
        canStop: Bool,
        canExport: Bool
    ) {
        let vm = RecordingViewModel()
        vm.state = state

        #expect(vm.canStartRecording == canStart)
        #expect(vm.canStopRecording == canStop)
        #expect(vm.canExport == canExport)
    }

    // MARK: - Defensive: Impossible States

    @Test("start recording while already recording is no-op")
    func startWhileRecordingIsNoOp() async {
        let vm = RecordingViewModel()
        await vm.startRecording()
        let originalStartTime = vm.startTime

        await vm.startRecording()

        #expect(vm.startTime == originalStartTime)
    }

    @Test("stop recording while idle is no-op")
    func stopWhileIdleIsNoOp() async {
        let vm = RecordingViewModel()

        await vm.stopRecording()

        #expect(vm.state == .idle)
        #expect(vm.data.isEmpty)
    }
}
```

## 4. MCP Schema

Not applicable — this is a development process guideline.

## 5. Constraints & Compliance

**Concurrency:** View model tests may require `@MainActor` if the view model is `@MainActor`-isolated. Follow existing concurrency guidelines.

**Scope:** This rule applies to **all SwiftUI views**. Even simple presentation views get a minimal state matrix (at minimum: default state). Consistency across the codebase outweighs the marginal cost of testing simpler views.

**No External Dependencies:** State-matrix testing uses only Swift Testing framework and the project's own types. No third-party libraries required.

**Definition of Done:** A view is not "implemented" until:
1. State matrix documented in test file
2. View model tests cover all states in the matrix
3. State transitions tested for all user-triggerable actions
4. Computed properties verified per state
5. "Impossible" state combinations tested defensively
6. Tests pass in `swift test`

## 6. Backend Abstraction

Not applicable.

## 7. Dependencies

**Internal Dependencies:** None

**External Dependencies:** None

## 8. Test Strategy

This proposal IS the test strategy. It defines what must be tested for every UI element.

**Two-layer testing model:**
- **View model tests (mandatory):** Verify state logic, transitions, computed properties, and async operations. These tests are the durable investment — they survive view rewrites and enable safe migration to new/different views without refactoring the test suite.
- **View hierarchy inspection (future, optional):** If wiring bugs between view model and view prove to be a recurring problem in practice, a lightweight inspection layer can be added later. See `02_IMPLEMENTATION_PLANS/IDEAS/ViewInspectorUITesting.md` for prior analysis.

**Validation:** The state matrix is validated by:
- Code review: reviewer checks that the matrix covers all state-driving properties
- Quality gate: a future auditor could verify that views with `@Observable` view models have corresponding test suites (stretch goal, not required for v1)

**Metrics:**
- Track number of views with state-matrix tests vs. total views
- Target: 100% of views have state-matrix tests before release

## 9. Architecture Decision Review

**ADR Check:**
- [x] No existing ADR for UI state testing
- [ ] Does not supersede an existing ADR
- [ ] Does not amend an existing ADR
- [x] New ADR required

**New ADR Draft:**
- Title: Mandatory State-Matrix Coverage for UI Views
- Category: testing
- Key decision: Every SwiftUI view must have a documented state matrix and corresponding view model tests before being marked complete. State logic lives in view models, tested with Swift Testing and zero external dependencies. View hierarchy inspection is deferred — view model testing catches the class of bugs (state propagation, wrong transitions, missing conditions) that have caused real failures. The state matrix is authored during design and updated during implementation.

## 10. Resolved Questions

1. ~~**Granularity threshold:**~~ **RESOLVED** — All SwiftUI views require a state matrix. Even simple views get at minimum a default-state entry. Consistency is more valuable than exemptions.
2. **State matrix location:** In the test file as a `// MARK: - State Matrix` section with a markdown table in a block comment at the top.
3. ~~**Combinatorial explosion:**~~ **RESOLVED** — Hybrid approach:
   - **≤ 3 state dimensions:** Full cross-product coverage (exhaustive)
   - **> 3 state dimensions:** View should be refactored into smaller views. The 3-dimension threshold serves as a **complexity signal** — exceeding it means the view likely needs decomposition.
   - **Always:** Every individual enum case and boolean value appears in at least one test
   - **Always:** Test "impossible" state combinations don't crash (defensive)
4. ~~**View model testing vs. view testing:**~~ **RESOLVED** — Test the view model. View models contain all testable state logic and survive view rewrites. View hierarchy inspection deferred to future need. If wiring bugs become a recurring problem, revisit with a minimal, owned inspection utility — not a third-party dependency.

## 11. Documentation Strategy

**Documentation Type:** Narrative article at `00_CORE_RULES/12_UI_TESTING.md`

**Complexity Threshold Check:**
- Does it combine 3+ APIs? No (it's a process rule)
- Does explanation require 50+ lines? Yes (examples, matrix template)
- Does it need theory/background context? Yes (why state matrices catch bugs manual testing misses)

The core rules document covers the state-matrix methodology, view model testing patterns, combinatorial strategy, and anti-patterns.
