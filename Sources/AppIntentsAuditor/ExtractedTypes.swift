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
    var parameters: [ExtractedParameter] = []
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
