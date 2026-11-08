import Foundation

struct ExtractedIntent: Sendable {
    let name: String
    let line: Int
    let column: Int
    /// Line of the declaration's first token, attributes included — a marker above them counts.
    var declarationLine: Int = 0
    var hasDescription: Bool = false
    /// Reaches Siri by a system schema, the tool trait, or conformance to its protocol.
    var hasAssistantIntent: Bool = false
    /// Exists to configure a widget, so there is no action for Siri to perform.
    var isWidgetConfiguration: Bool = false
    var hasPerform: Bool = false
    /// Carries the tool trait (or `ToolIntent`), so Siri may call it.
    var isTool: Bool = false
    /// The domain of an `@AppIntent(schema: .domain.name)` argument, as written.
    var schemaDomain: String?
    /// `static var isDiscoverable = false`: not offered to Shortcuts.
    var isHiddenFromShortcuts: Bool = false
    var parameters: [ExtractedParameter] = []
    /// Names referenced inside any function body of the intent, `$x` and `_x` folded to `x`.
    var referencedInFunctions: Set<String> = []
}

struct ExtractedParameter: Sendable {
    let name: String
    let line: Int
    let column: Int
    var hasTitle: Bool = false
}

struct ExtractedEntity: Sendable {
    let name: String
    let line: Int
    let column: Int
    var hasDisplayRepresentation: Bool = false
    var hasTypeDisplayRepresentation: Bool = false
    var hasId: Bool = false
    var hasDefaultQuery: Bool = false
    var hasAssistantEntity: Bool = false
    var undescribedProperties: [ExtractedEntityProperty] = []
    /// Named like sensitive data, with no property-level policy.
    var sensitiveProperties: [ExtractedEntityProperty] = []
    var hasAuthenticationPolicy: Bool = false
}

/// A `@Property`, `@DeferredProperty` or `@ComputedProperty` Siri would read.
struct ExtractedEntityProperty: Sendable {
    let name: String
    let line: Int
    let column: Int
}

struct ExtractedEnum: Sendable {
    let name: String
    let line: Int
    let column: Int
    var cases: [String] = []
    var hasTypeDisplayRepresentation: Bool = false
    var displayedCases: Set<String> = []
    var hasAssistantEnum: Bool = false
}
