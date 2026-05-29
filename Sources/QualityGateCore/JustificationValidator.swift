import Foundation

/// Validates justification comment quality to prevent gaming the override system
/// with vague or low-effort comments like `// Justification: safe`.
///
/// Used by auditors that support justification-based overrides (ConcurrencyAuditor,
/// SafetyAuditor, etc.) to enforce a minimum quality bar on exemption comments.
public struct JustificationValidator: Sendable {

    /// The result of validating a justification comment.
    public enum ValidationResult: Sendable, Equatable {
        /// The justification meets quality requirements.
        case valid
        /// The justification has too few words to be meaningful.
        case tooShort(wordCount: Int)
        /// The justification matches a known low-effort phrase.
        case generic(matchedPhrase: String)
        /// The same justification text was already used elsewhere.
        case duplicate
    }

    /// Known low-effort phrases that do not constitute a real justification.
    private static let denylist: Set<String> = [
        "safe", "needed", "legacy", "works fine", "temporary",
        "will fix later", "not a problem", "required", "necessary",
        "trust me", "it's fine", "no issue", "known safe"
    ]

    /// Minimum word count for a justification to be considered substantive.
    private static let minimumWordCount = 8

    /// Creates a new justification validator.
    public init() {}

    /// Validates the quality of a justification comment.
    ///
    /// - Parameters:
    ///   - justificationText: The full comment text (may include the keyword prefix).
    ///   - keyword: The justification keyword to strip before validation.
    /// - Returns: A ``ValidationResult`` indicating whether the justification is acceptable.
    public func validate(_ justificationText: String, keyword: String = "Justification:") -> ValidationResult {
        let text = extractPayload(from: justificationText, keyword: keyword)
        let words = text.split(whereSeparator: { $0.isWhitespace })
        let lowered = text.lowercased()

        for phrase in Self.denylist {
            if lowered == phrase
                || lowered == phrase + "."
                || lowered.hasPrefix(phrase + ".")
                || lowered.hasPrefix(phrase + ",") {
                return .generic(matchedPhrase: phrase)
            }
        }

        if words.count < Self.minimumWordCount {
            return .tooShort(wordCount: words.count)
        }

        return .valid
    }

    /// Validates a justification for quality and duplicate usage.
    ///
    /// - Parameters:
    ///   - justificationText: The full comment text (may include the keyword prefix).
    ///   - seen: A set tracking previously seen justification texts; updated in-place.
    ///   - keyword: The justification keyword to strip before validation.
    /// - Returns: A ``ValidationResult`` indicating whether the justification is acceptable.
    public func validateForDuplicates(
        _ justificationText: String,
        seen: inout Set<String>,
        keyword: String = "Justification:"
    ) -> ValidationResult {
        let result = validate(justificationText, keyword: keyword)
        guard case .valid = result else { return result }

        let text = extractPayload(from: justificationText, keyword: keyword)
        let normalized = text.lowercased()

        if seen.contains(normalized) {
            return .duplicate
        }
        seen.insert(normalized)
        return .valid
    }

    // MARK: - Private

    private func extractPayload(from justificationText: String, keyword: String) -> String {
        if let range = justificationText.range(of: keyword) {
            return String(justificationText[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return justificationText.trimmingCharacters(in: .whitespaces)
    }
}
