# AppIntentsAuditor Guide

Why App Intents completeness matters for Apple Intelligence, what each rule checks, and how to configure the auditor for your project.

## Why this auditor exists

Apple Intelligence, Shortcuts, Spotlight, and Siri discover your app's capabilities through App Intents. But declaring a struct that conforms to `AppIntent` is only the first step. For an intent to actually surface to users, it needs:

- A human-readable **description** (so Siri can explain what it does)
- Titled **parameters** (so Shortcuts can label each input field)
- An **`@AssistantIntent` schema annotation** (so Apple Intelligence knows which system action it maps to)

The same pattern applies to `AppEntity` (needs display representations and `@AssistantEntity`) and `AppEnum` (needs type display, case displays, and `@AssistantEnum`).

Missing any of these is not a compiler error. Your code builds and runs. But the intent is invisible to the user -- or worse, partially visible with unlabeled parameters and no description. These are the bugs that slip through code review because they are omissions, not mistakes.

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
// flagged
struct OpenApp: AppIntent {
    static var title: LocalizedStringResource = "Open App"
    func perform() async throws -> some IntentResult { .result() }
}

// accepted
struct OpenApp: AppIntent {
    static var title: LocalizedStringResource = "Open App"
    static var description: IntentDescription = "Opens the app to the main screen"
    func perform() async throws -> some IntentResult { .result() }
}
```

#### `appintent-param-no-title`

Every `@Parameter` needs a `title` argument so Shortcuts can label the input field. A parameter without a title renders as an unlabeled text field in the Shortcuts editor.

```swift
// flagged
@Parameter var query: String

// accepted
@Parameter(title: "Search Query") var query: String
```

#### `appintent-no-assistant-schema`

For Apple Intelligence integration, intents should be annotated with `@AssistantIntent(schema:)` to map to a system action category.

```swift
// flagged
struct SearchItems: AppIntent {
    static var title: LocalizedStringResource = "Search"
    static var description: IntentDescription = "Searches items"
    func perform() async throws -> some IntentResult { .result() }
}

// accepted
@AssistantIntent(schema: .system.search)
struct SearchItems: AppIntent {
    static var title: LocalizedStringResource = "Search"
    static var description: IntentDescription = "Searches items"
    func perform() async throws -> some IntentResult { .result() }
}
```

### Entity completeness

#### `appintent-entity-no-display`

Every `AppEntity` needs a `displayRepresentation` property so the system can render it in UI.

```swift
// flagged -- missing displayRepresentation
struct Item: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Item"
    var id: String
    static var defaultQuery = ItemQuery()
}
```

#### `appintent-entity-no-type-display`

Every `AppEntity` needs a `typeDisplayRepresentation` so the system knows how to label the entity type in plural and singular contexts.

#### `appintent-entity-not-assistant`

For Apple Intelligence, entities should be annotated with `@AssistantEntity(schema:)`.

### Enum completeness

#### `appintent-enum-no-display`

Every `AppEnum` needs a `typeDisplayRepresentation` so the system can label the enum type.

#### `appintent-enum-case-no-display`

Every case in an `AppEnum` must have an entry in `caseDisplayRepresentations`. Missing cases render as raw enum values in the Shortcuts picker.

```swift
// flagged -- "medium" case missing from display representations
enum Priority: String, AppEnum {
    case low, medium, high
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Priority"
    static var caseDisplayRepresentations: [Priority: DisplayRepresentation] = [
        .low: "Low",
        .high: "High",
        // medium is missing
    ]
}
```

#### `appintent-enum-not-assistant`

For Apple Intelligence, enums should be annotated with `@AssistantEnum(schema:)`.

## How detection works

AppIntentsAuditor uses SwiftSyntax to parse each file that contains `import AppIntents`. It does not compile the code or resolve types -- it operates on the syntax tree alone.

**Intent detection:** Any `struct` whose inheritance clause includes `AppIntent` is treated as an intent. The visitor then checks for:
- A `static var description` property whose type or initializer mentions `IntentDescription`
- `@Parameter` attributes with and without `title:` arguments
- An `@AssistantIntent` attribute on the struct declaration

**Entity detection:** Any `struct` whose inheritance clause includes `AppEntity` is treated as an entity. The visitor checks for `displayRepresentation`, `typeDisplayRepresentation`, and `@AssistantEntity`.

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

  warning: AppIntent 'OpenPortfolio' has no @AssistantIntent annotation
    -> Sources/Intents/OpenPortfolio.swift:3
    appintent-no-assistant-schema
```

Each diagnostic includes the rule ID, the file and line number, and a human-readable message. The auditor emits warnings, not errors -- missing metadata does not prevent compilation, but it does prevent discoverability.

## Relationship to Apple Intelligence

Apple Intelligence (introduced in iOS 18 / macOS 15) uses `@AssistantIntent`, `@AssistantEntity`, and `@AssistantEnum` annotations to integrate your app's intents into the system-wide AI assistant. Without these annotations, your intents still work in Shortcuts but are invisible to Apple Intelligence.

The auditor's assistant-schema rules (`appintent-no-assistant-schema`, `appintent-entity-not-assistant`, `appintent-enum-not-assistant`) specifically target this integration surface. If your app does not target Apple Intelligence, these rules can be suppressed per-intent by adding the annotation with any appropriate schema.

## Future: cross-file analysis (Pass 2)

The `useIndexStore` configuration flag is reserved for a future cross-file analysis pass using IndexStoreInfra. When implemented, Pass 2 will:

- Resolve `AppIntent` conformance through protocol composition and typealiases across files
- Detect entities referenced by intents but missing required display representations
- Verify that `AppShortcutsProvider` actually references declared intents
- Track `@Parameter` types across module boundaries

Pass 2 will follow the same graceful degradation pattern used by UnreachableCodeAuditor: if the index is unavailable, it emits a `.note` and falls back to Pass 1 results only.
