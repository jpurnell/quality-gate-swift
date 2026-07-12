import Foundation

/// The org's review policy over escape hatches (Phase 3b §3).
///
/// Rule patterns are fnmatch-style globs with `*` as the only wildcard
/// (e.g. `"safety.*"`). A rule matching both lists requires review —
/// tightening never loosens. An absent policy means everything is
/// self-acknowledgeable: today's solo behavior exactly.
public struct ReviewPolicy: Sendable, Codable, Equatable {

    /// Glob patterns for rules whose overrides need a distinct second
    /// verified identity (e.g. `"safety.*"`).
    public let requiresSecondReviewer: [String]
    /// Glob patterns for rules whose acknowledgments stay lightweight
    /// (e.g. `"legibility.*"`). Informational where it overlaps
    /// ``requiresSecondReviewer`` — the tighter list always wins.
    public let selfAcknowledgeAllowed: [String]

    /// Creates a review policy.
    /// - Parameters:
    ///   - requiresSecondReviewer: Patterns requiring a second reviewer.
    ///   - selfAcknowledgeAllowed: Patterns kept self-acknowledgeable.
    public init(requiresSecondReviewer: [String] = [], selfAcknowledgeAllowed: [String] = []) {
        self.requiresSecondReviewer = requiresSecondReviewer
        self.selfAcknowledgeAllowed = selfAcknowledgeAllowed
    }

    private enum CodingKeys: String, CodingKey {
        case requiresSecondReviewer
        case selfAcknowledgeAllowed
    }

    /// Decodes a policy from its YAML-shaped JSON form; absent keys
    /// default to empty lists so a minimal policy file stays minimal.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requiresSecondReviewer = try container.decodeIfPresent(
            [String].self, forKey: .requiresSecondReviewer) ?? []
        self.selfAcknowledgeAllowed = try container.decodeIfPresent(
            [String].self, forKey: .selfAcknowledgeAllowed) ?? []
    }

    /// Whether overriding `ruleId` needs a distinct second reviewer.
    ///
    /// True when any ``requiresSecondReviewer`` pattern matches — even if a
    /// ``selfAcknowledgeAllowed`` pattern also matches, because tightening
    /// never loosens.
    /// - Parameter ruleId: The rule identifier (e.g. `"safety.force-unwrap"`).
    /// - Returns: `true` when the override must be held for review.
    public func requiresSecondReviewer(for ruleId: String) -> Bool {
        requiresSecondReviewer.contains { Self.globMatches(pattern: $0, value: ruleId) }
    }

    /// Anchored fnmatch-style match with `*` as the only wildcard.
    ///
    /// Iterative greedy backtracking — no recursion, no regular
    /// expressions, no locale sensitivity.
    static func globMatches(pattern: String, value: String) -> Bool {
        let patternChars = Array(pattern)
        let valueChars = Array(value)
        var patternIndex = 0
        var valueIndex = 0
        var starIndex = -1
        var starMark = 0

        while valueIndex < valueChars.count {
            if patternIndex < patternChars.count,
               patternChars[patternIndex] == "*" {
                starIndex = patternIndex
                starMark = valueIndex
                patternIndex += 1
            } else if patternIndex < patternChars.count,
                      patternChars[patternIndex] == valueChars[valueIndex] {
                patternIndex += 1
                valueIndex += 1
            } else if starIndex >= 0 {
                // Backtrack: let the last `*` absorb one more character.
                patternIndex = starIndex + 1
                starMark += 1
                valueIndex = starMark
            } else {
                return false
            }
        }
        while patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternChars.count
    }
}

/// A governed override held for a second identity (Phase 3b §3).
///
/// Held is a recorded state — visible on the dashboard, never silently
/// accepted, never lost. Approval and rejection are artifacts.
public struct PendingReview: Sendable, Codable, Equatable {

    /// The review's lifecycle state.
    public enum State: Sendable, Codable, Equatable {
        /// Awaiting a distinct second verified identity.
        case pending
        /// Approved by a second identity at the recorded time.
        case approved(by: String, at: Date)
        /// Rejected by a second identity, with the recorded reason.
        case rejected(by: String, at: Date, reason: String)
    }

    /// Stable identifier (UUID string) used to approve or reject.
    public let id: String
    /// The rule the override targets (e.g. `"safety.force-unwrap"`).
    public let ruleId: String
    /// The submitter's stated justification.
    public let justification: String
    /// The verified identity that submitted the override.
    public let submittedBy: String
    /// When the override was submitted.
    public let submittedAt: Date
    /// The review's current state.
    public internal(set) var state: State

    /// Creates a review record.
    /// - Parameters:
    ///   - id: Stable identifier (UUID string).
    ///   - ruleId: The rule the override targets.
    ///   - justification: The submitter's stated justification.
    ///   - submittedBy: The verified identity that submitted it.
    ///   - submittedAt: Submission timestamp.
    ///   - state: The review's state.
    public init(
        id: String,
        ruleId: String,
        justification: String,
        submittedBy: String,
        submittedAt: Date,
        state: State
    ) {
        self.id = id
        self.ruleId = ruleId
        self.justification = justification
        self.submittedBy = submittedBy
        self.submittedAt = submittedAt
        self.state = state
    }
}
