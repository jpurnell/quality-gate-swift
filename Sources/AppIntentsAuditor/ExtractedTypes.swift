import Foundation

struct ExtractedIntent: Sendable {
    let name: String
    let line: Int
    let column: Int
    var hasDescription: Bool = false
    var hasAssistantIntent: Bool = false
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
