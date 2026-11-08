# AppIntentsAuditor Guide

Why App Intents completeness matters for Apple Intelligence, what each rule checks, and how to configure the auditor for your project.

## Why this auditor exists

Apple Intelligence, Shortcuts, Spotlight, and Siri discover your app's capabilities through App Intents. But declaring a struct that conforms to `AppIntent` is only the first step. For an intent to actually surface to users, it needs:

- A human-readable **description** (so Siri can explain what it does)
- Titled **parameters** (so Shortcuts can label each input field)
- A **route to Siri**: a system schema (`@AppIntent(schema:)`) when one fits, or the tool trait (`@AppIntent(.tool)`) for a custom action

The same pattern applies to `AppEntity` (needs display representations) and `AppEnum` (needs type display and case displays). Both can also adopt a schema (`@AppEntity(schema:)`, `@AppEnum(schema:)`), which is optional and reported as a note.

Missing any of these is not a compiler error -- and in the one case where it technically is, an entity's display representation, the requirement is easily satisfied out of sight in an extension. Your code builds and runs. But the intent is invisible to the user -- or worse, partially visible with unlabeled parameters and no description. These are the bugs that slip through code review because they are omissions, not mistakes.

AppIntentsAuditor catches these omissions at build time with 17 diagnostic rules across 5 categories.

## Getting started

AppIntentsAuditor is **opt-in** (disabled by default) because most projects do not use App Intents. Enable it in your `.quality-gate.yml`:

```yaml
appIntentsReadiness:
  enabled: true
```

The auditor automatically skips files that do not `import AppIntents`, so enabling it on a project without App Intents produces no diagnostics and no meaningful overhead.

## Rule walkthrough

### Intent completeness

#### `appintent-no-description`

Every `AppIntent` should have an `IntentDescription` so Shortcuts and Siri can tell the user what the intent does.

```swift
import AppIntents

// flagged
struct OpenApp: AppIntent {
    static let title: LocalizedStringResource = "Open App"
    func perform() async throws -> some IntentResult { .result() }
}

// accepted
struct DescribedOpenApp: AppIntent {
    static let title: LocalizedStringResource = "Open App"
    static let description: IntentDescription = "Opens the app to the main screen"
    func perform() async throws -> some IntentResult { .result() }
}
```

#### `appintent-param-no-title`

Every `@Parameter` needs a `title` argument so Shortcuts can label the input field. A parameter without a title renders as an unlabeled text field in the Shortcuts editor.

```swift
// flagged
struct UntitledParameterSearch: AppIntent {
    static let title: LocalizedStringResource = "Search"
    @Parameter var query: String
    func perform() async throws -> some IntentResult { .result() }
}

// accepted
struct TitledParameterSearch: AppIntent {
    static let title: LocalizedStringResource = "Search"
    @Parameter(title: "Search Query") var query: String
    func perform() async throws -> some IntentResult { .result() }
}
```

#### `appintent-no-assistant-schema`

An intent that performs a custom action needs a route to Siri. There are two:

- **A system schema**, `@AppIntent(schema:)`, when one of Apple's app schema domains describes the action. A schema in a primary domain already makes the action available to Siri.
- **The tool trait**, `@AppIntent(.tool)`, for a custom action no schema describes. Use `@AppIntent(.tool, schema:)` for a schema from a Shortcuts-specific domain (journaling, books, files and similar), which supports Shortcuts but not Siri on its own.

Conforming to the `AssistantIntent` or `ToolIntent` protocol also counts; those are what the macros conform the type to. An intent that conforms to `WidgetConfigurationIntent`, or that has no `perform()`, is not asked for a route: it has no action for Siri to run.

```swift
// flagged: a custom action with no route to Siri
struct AddToCartWithoutRoute: AppIntent {
    static let title: LocalizedStringResource = "Add to Cart"
    static let description: IntentDescription = "Adds a product to the cart"
    func perform() async throws -> some IntentResult { .result() }
}
```

The accepted form needs the 27.3 SDK, which is newer than the one this article is compiled against, so it is shown as text rather than as part of the program:

```text
// accepted
@AppIntent(.tool)
struct AddToCart: AppIntent {
    static let title: LocalizedStringResource = "Add to Cart"
    static let description: IntentDescription = "Adds a product to the cart"
    func perform() async throws -> some IntentResult { .result() }
}
```

The tool trait is part of the Siri AI Developer Preview, and Apple notes the API may change during the preview.

### Declining a surface on purpose

An intent can stay out of Siri, Shortcuts or MCP deliberately. Say so, and say why:

```swift
// appintents:exempt siri — rewrites the ledger and must only ever run from inside the app
struct RewriteLedgerInApp: AppIntent {
    static let title: LocalizedStringResource = "Rewrite Ledger"
    static let description: IntentDescription = "Rewrites the ledger"
    func perform() async throws -> some IntentResult { .result() }
}
```

The marker is `appintents:exempt <surface>`, where the surface is `siri`, `shortcuts`, `mcp` or `auth`, followed by a reason. It may sit on the line above the declaration (above any attributes) or on the declaration's own line.

- **A reason is required.** A marker with none does not count: the finding stays and `appintent.exempt-no-justification` is reported.
- **It is recorded, never silent.** A marker with a reason silences the finding and appears in the override report with its reason, which the shared reason validator also judges.
- **One surface covers only that surface.** `shortcuts` and `mcp` do not silence the Siri rule, and an unrecognised name is reported as `appintent.exempt-unknown-surface`.
- **`siri` and `auth` have rules to answer today.** `auth` declines `appintent-sensitive-no-auth` and sits on the property. `shortcuts` and `mcp` are accepted so the syntax will not change when their rules arrive.

Shortcuts also has a declaration that needs no comment: `static var isDiscoverable = false` hides an intent from Shortcuts in code. Combined with the tool trait it is flagged by `appintent-hidden-tool`, because the intent is then still a Siri tool.

#### `appintent-schema-shortcuts-only`

A warning. Apple's schema domains split in two. A primary domain's schemas reach Siri; a Shortcuts-specific domain's (books, browser, files, journaling, presentation, reader, spreadsheet, whiteboard, word processor) support Shortcuts but not Siri. An intent that adopts one of the second kind looks finished and is invisible to Siri unless it also carries the tool trait.

```text
@AppIntent(.tool, schema: .journal.createEntry)
```

The domain table is one data file, with Apple's page beside it, because it is the part most likely to change during the preview.

#### `appintent-tool-no-perform`

A warning. The tool trait on an intent with no `perform()` (a `WidgetConfigurationIntent`, for example) gives Siri nothing to run. Apple says such an intent is not a tool.

#### `appintent-tool-with-siri-schema`

A note. Apple says not to add the tool trait to an intent that already conforms to a primary-domain schema, since that already reaches Siri.

#### `appintent-hidden-tool`

A warning. An intent that carries the tool trait and also sets `static var isDiscoverable = false` is hidden from Shortcuts but still callable by Siri. That is legal and sometimes intended, so the rule exists to make the choice visible early, not to forbid it. Remove `isDiscoverable = false` to offer the intent to Shortcuts, or drop the tool trait if Siri should not call it.

### Entity completeness

#### `appintent-entity-no-display`

Every `AppEntity` needs a `displayRepresentation` property so the system can render it in UI. It is a protocol requirement, so an entity that omits it outright will not compile at all -- which makes the interesting case the one that *does* compile, where the requirement is satisfied off to the side in an extension. The visitor reads only the struct body, so it still flags the declaration, and so would any reader trying to answer "how does this entity render?" by looking at the entity.

```swift
struct LibraryItemQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [LibraryItem] {
        identifiers.map { LibraryItem(id: $0) }
    }
}

// flagged -- no displayRepresentation on the struct itself
struct LibraryItem: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Library Item"
    var id: String
    static let defaultQuery = LibraryItemQuery()
}

// satisfies the compiler, but out of the visitor's reach
extension LibraryItem {
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Item \(id)")
    }
}
```

Moving that property onto `LibraryItem` itself clears the diagnostic.

#### `appintent-entity-no-type-display`

Every `AppEntity` needs a `typeDisplayRepresentation` so the system knows how to label the entity type in plural and singular contexts.

#### `appintent-property-no-description`

A warning. Siri reads the `description` of each `@Property`, `@DeferredProperty` and `@ComputedProperty` to decide what the property means, as it reads an intent's description.

```text
@Property(title: "Balance", description: "What the account holds today, in its own currency")
var balance: Double
```

A property Siri should not see takes `visibility: .internal` instead and needs no description.

#### `appintent-sensitive-no-auth`

A warning. A property named like money, credentials or health data (`balance`, `password`, `token`, `salary`, `diagnosis` and a few others, matched as whole words of the camel-case name) with no `IntentAuthenticationPolicy`, at the property or on the entity. Without one, Siri may read the value out on a locked device.

This is a name heuristic, so it has a recorded decline. A reason is required, and the decline is reported with the other overrides:

```text
// appintents:exempt auth — a running total of public donations, nothing personal
@Property(title: "Balance", description: "Donations received to date")
var balance: Double
```

#### `appintent-entity-not-assistant`

A note, not a warning. A schema (`@AppEntity(schema:)`), where one fits the type, tells Siri and Shortcuts what it is. A custom entity does not need one: it reaches Siri through its property descriptions and Spotlight. Conforming to `AssistantEntity` also counts.

### Enum completeness

#### `appintent-enum-no-display`

Every `AppEnum` needs a `typeDisplayRepresentation` so the system can label the enum type.

#### `appintent-enum-case-no-display`

Every case in an `AppEnum` must have an entry in `caseDisplayRepresentations`. Missing cases render as raw enum values in the Shortcuts picker.

```swift
// flagged -- "medium" case missing from display representations
enum Priority: String, AppEnum {
    case low, medium, high
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Priority"
    static let caseDisplayRepresentations: [Priority: DisplayRepresentation] = [
        .low: "Low",
        .high: "High",
        // medium is missing
    ]
}
```

#### `appintent-enum-not-assistant`

A note, not a warning, on the same terms as the entity rule: `@AppEnum(schema:)` is optional, and conforming to `AssistantEnum` also counts.

## How detection works

AppIntentsAuditor uses SwiftSyntax to parse each file that contains `import AppIntents`. It does not compile the code or resolve types -- it operates on the syntax tree alone.

**Intent detection:** Any `struct` whose inheritance clause includes `AppIntent` is treated as an intent. The visitor then checks for:
- A `static let` or `static var` named `description` whose type or initializer mentions `IntentDescription`
- `@Parameter` attributes with and without `title:` arguments
- A route to Siri: an `@AppIntent(...)` attribute, or conformance to `AssistantIntent` or `ToolIntent`

**Entity detection:** Any `struct` whose inheritance clause includes `AppEntity` is treated as an entity. The visitor checks for `displayRepresentation`, `typeDisplayRepresentation`, and an `@AppEntity` attribute or `AssistantEntity` conformance.

**Enum detection:** Any `enum` whose inheritance clause includes `AppEnum` is treated as an enum. The visitor extracts case names from the enum body and checks them against the keys in `caseDisplayRepresentations`.

This syntax-based approach means the auditor works without a build, without an index store, and without resolving imports. It will not detect intents that conform to `AppIntent` through a typealias or protocol composition, but these patterns are rare in practice.

## Configuration

```yaml
appIntentsReadiness:
  enabled: true                    # default: false
  minDescriptionLength: 10         # default: 10
  excludePaths:                    # default: []
    - "**/Generated/**"
  requireShortcutsProvider: false  # default: false
  auditEntities: true              # default: true
  auditEnums: true                 # default: true
  useIndexStore: true              # default: true (reserved for future Pass 2)
```

**`enabled`** -- Must be `true` for the auditor to run. This is the only required setting.

**`minDescriptionLength`** -- Minimum character length for intent descriptions. Descriptions shorter than this emit a warning. Set to 0 to disable length checking.

**`excludePaths`** -- Glob patterns for files to skip. Useful for excluding generated code or third-party wrappers.

**`requireShortcutsProvider`** -- When `true`, emits a warning if no `AppShortcutsProvider` is found in the project. This is an advanced check for apps that want to guarantee their intents appear in the Shortcuts app.

**`auditEntities`** / **`auditEnums`** -- Toggle entity and enum auditing independently. Useful if your project uses intents but not custom entities or enums.

**`useIndexStore`** -- Reserved for a future Pass 2 that uses IndexStoreDB for cross-file conformance resolution. Currently has no effect.

## Understanding the results

A typical quality-gate run on a project with App Intents:

```
[appintents-readiness] WARNING (0.12s)
  warning: AppIntent 'OpenPortfolio' has no IntentDescription
    -> Sources/Intents/OpenPortfolio.swift:5
    appintent-no-description

  warning: @Parameter 'portfolio' in 'OpenPortfolio' has no title
    -> Sources/Intents/OpenPortfolio.swift:8
    appintent-param-no-title

  warning: AppIntent 'OpenPortfolio' has no route to Siri: no system schema and no tool trait.
    -> Sources/Intents/OpenPortfolio.swift:3
    appintent-no-assistant-schema
```

Each diagnostic includes the rule ID, the file and line number, and a human-readable message. The auditor emits warnings, not errors -- missing metadata does not prevent compilation, but it does prevent discoverability.

## Relationship to Apple Intelligence

Apple Intelligence (iOS 18 and macOS 15) introduced the `AssistantIntent` and `AssistantEntity` protocols, which the `@AppIntent(schema:)` and `@AppEntity(schema:)` macros conform a type to. The Siri AI Developer Preview adds the tool trait for custom actions that no schema describes. These are protocols and macros; there is no `@AssistantIntent` attribute, and an earlier version of this auditor looked for one.

`appintent-no-assistant-schema` is the one rule here that warns, and it asks only that a custom action have some route to Siri. The entity and enum rules are notes. 
## Future: cross-file analysis (Pass 2)

The `useIndexStore` configuration flag is reserved for a future cross-file analysis pass using IndexStoreInfra. When implemented, Pass 2 will:

- Resolve `AppIntent` conformance through protocol composition and typealiases across files
- Detect entities referenced by intents but missing required display representations
- Verify that `AppShortcutsProvider` actually references declared intents
- Track `@Parameter` types across module boundaries

Pass 2 will follow the same graceful degradation pattern used by UnreachableCodeAuditor: if the index is unavailable, it emits a `.note` and falls back to Pass 1 results only.
