import Foundation
import Testing
@testable import CorpusService

/// Phase 3b §3 — review policy glob semantics.
///
/// Matching is fnmatch-style with `*` as the only wildcard. A rule that
/// matches both lists requires review — tightening never loosens.
@Suite("ReviewPolicy")
struct ReviewPolicyTests {

    private let policy = ReviewPolicy(
        requiresSecondReviewer: ["safety.*", "concurrency.unchecked-sendable"],
        selfAcknowledgeAllowed: ["legibility.*"])

    @Test("'safety.*' matches rules in the safety namespace")
    func safetyGlobMatches() {
        #expect(policy.requiresSecondReviewer(for: "safety.force-unwrap"))
        #expect(policy.requiresSecondReviewer(for: "safety.force-cast"))
    }

    @Test("'safety.*' does not match other namespaces or the bare prefix")
    func safetyGlobDoesNotOvermatch() {
        #expect(!policy.requiresSecondReviewer(for: "concurrency.x"))
        #expect(!policy.requiresSecondReviewer(for: "safety"))
        #expect(!policy.requiresSecondReviewer(for: "unsafety.force-unwrap"))
    }

    @Test("an exact rule id in the list matches only itself")
    func exactPatternMatches() {
        #expect(policy.requiresSecondReviewer(for: "concurrency.unchecked-sendable"))
        #expect(!policy.requiresSecondReviewer(for: "concurrency.unchecked-sendable-ish"))
        #expect(!policy.requiresSecondReviewer(for: "concurrency.unchecked"))
    }

    @Test("self-acknowledgeable rules do not require review")
    func selfAcknowledgeAllowedDoesNotRequireReview() {
        #expect(!policy.requiresSecondReviewer(for: "legibility.long-name"))
    }

    @Test("a rule matching both lists requires review — tightening wins")
    func bothListsTightensToReview() {
        let overlapping = ReviewPolicy(
            requiresSecondReviewer: ["safety.*"],
            selfAcknowledgeAllowed: ["safety.*"])
        #expect(overlapping.requiresSecondReviewer(for: "safety.force-unwrap"))
    }

    @Test("an empty policy requires nothing")
    func emptyPolicyRequiresNothing() {
        let empty = ReviewPolicy(requiresSecondReviewer: [], selfAcknowledgeAllowed: [])
        #expect(!empty.requiresSecondReviewer(for: "safety.force-unwrap"))
    }

    @Test("a bare '*' pattern matches every rule")
    func bareStarMatchesEverything() {
        let strict = ReviewPolicy(requiresSecondReviewer: ["*"], selfAcknowledgeAllowed: [])
        #expect(strict.requiresSecondReviewer(for: "safety.force-unwrap"))
        #expect(strict.requiresSecondReviewer(for: "legibility.long-name"))
    }

    @Test("decoding an empty object defaults both lists to empty")
    func decodeDefaultsToEmpty() throws {
        let decoded = try JSONDecoder().decode(
            ReviewPolicy.self, from: Data("{}".utf8))
        #expect(decoded == ReviewPolicy(requiresSecondReviewer: [], selfAcknowledgeAllowed: []))
    }

    @Test("decoding fills only the keys present, defaulting the rest")
    func decodePartialObject() throws {
        let json = #"{"requiresSecondReviewer": ["safety.*"]}"#
        let decoded = try JSONDecoder().decode(
            ReviewPolicy.self, from: Data(json.utf8))
        #expect(decoded.requiresSecondReviewer == ["safety.*"])
        #expect(decoded.selfAcknowledgeAllowed == [])
    }
}
