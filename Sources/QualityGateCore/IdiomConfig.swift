import Foundation

/// Configuration knobs for ``IdiomAuditor``.
///
/// All properties have defaults, and the custom `Decodable` conformance uses
/// `decodeIfPresent` throughout, so a partial (or absent) `idiom:` section in
/// `.quality-gate.yml` decodes to sensible defaults.
public struct IdiomConfig: Sendable, Codable, Equatable {
    /// Escalate every idiom finding from `.note` to `.warning`. The check
    /// status remains `.passed` either way — idiom findings are advisory.
    public var escalateToWarning: Bool
    /// Minimum length for variable/function/parameter names (`idiom.identifier-name`).
    public var minIdentifierLength: Int
    /// Short names exempt from the minimum-length check (`idiom.identifier-name`).
    public var allowedShortIdentifiers: [String]
    /// Regex a TODO/FIXME comment must match to count as ticketed (`idiom.todo-policy`).
    public var todoTicketPattern: String
    /// Maximum number of lines per file (`idiom.file-length`).
    public var maxFileLength: Int
    /// Maximum number of lines between a function's braces (`idiom.function-body-length`).
    public var maxFunctionBodyLength: Int
    /// Maximum characters per line; URL-only lines are exempt (`idiom.line-length`).
    public var maxLineLength: Int
    /// Maximum run of consecutive blank lines (`idiom.vertical-whitespace`).
    public var maxConsecutiveBlankLines: Int
    /// Maximum length for type names (`idiom.type-name`).
    public var maxTypeNameLength: Int

    /// Creates an idiom configuration; every knob defaults to the documented value.
    public init(
        escalateToWarning: Bool = false,
        minIdentifierLength: Int = 2,
        allowedShortIdentifiers: [String] = ["i", "j", "k", "x", "y", "z", "id", "to", "at", "in", "dx", "dy"],
        todoTicketPattern: String = "[A-Z]+-[0-9]+|#[0-9]+",
        maxFileLength: Int = 1000,
        maxFunctionBodyLength: Int = 100,
        maxLineLength: Int = 200,
        maxConsecutiveBlankLines: Int = 2,
        maxTypeNameLength: Int = 50
    ) {
        self.escalateToWarning = escalateToWarning
        self.minIdentifierLength = minIdentifierLength
        self.allowedShortIdentifiers = allowedShortIdentifiers
        self.todoTicketPattern = todoTicketPattern
        self.maxFileLength = maxFileLength
        self.maxFunctionBodyLength = maxFunctionBodyLength
        self.maxLineLength = maxLineLength
        self.maxConsecutiveBlankLines = maxConsecutiveBlankLines
        self.maxTypeNameLength = maxTypeNameLength
    }

    private enum CodingKeys: String, CodingKey {
        case escalateToWarning, minIdentifierLength, allowedShortIdentifiers
        case todoTicketPattern, maxFileLength, maxFunctionBodyLength
        case maxLineLength, maxConsecutiveBlankLines, maxTypeNameLength
    }

    /// Decodes with defaults for absent keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = IdiomConfig()
        escalateToWarning = try container.decodeIfPresent(Bool.self, forKey: .escalateToWarning)
            ?? defaults.escalateToWarning
        minIdentifierLength = try container.decodeIfPresent(Int.self, forKey: .minIdentifierLength)
            ?? defaults.minIdentifierLength
        allowedShortIdentifiers = try container.decodeIfPresent([String].self, forKey: .allowedShortIdentifiers)
            ?? defaults.allowedShortIdentifiers
        todoTicketPattern = try container.decodeIfPresent(String.self, forKey: .todoTicketPattern)
            ?? defaults.todoTicketPattern
        maxFileLength = try container.decodeIfPresent(Int.self, forKey: .maxFileLength)
            ?? defaults.maxFileLength
        maxFunctionBodyLength = try container.decodeIfPresent(Int.self, forKey: .maxFunctionBodyLength)
            ?? defaults.maxFunctionBodyLength
        maxLineLength = try container.decodeIfPresent(Int.self, forKey: .maxLineLength)
            ?? defaults.maxLineLength
        maxConsecutiveBlankLines = try container.decodeIfPresent(Int.self, forKey: .maxConsecutiveBlankLines)
            ?? defaults.maxConsecutiveBlankLines
        maxTypeNameLength = try container.decodeIfPresent(Int.self, forKey: .maxTypeNameLength)
            ?? defaults.maxTypeNameLength
    }
}
