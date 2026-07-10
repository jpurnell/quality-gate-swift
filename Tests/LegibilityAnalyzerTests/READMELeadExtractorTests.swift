import Foundation
import Testing
@testable import LegibilityAnalyzer

/// Phase 1, workstream 3 — README lead extraction.
///
/// On repos without our description conventions (`// legibility:description:`
/// or a Master Plan Mission), `orient` falls back to the README's first
/// meaningful paragraph so orientation cards are never prose-empty.
@Suite("READMELeadExtractor")
struct READMELeadExtractorTests {

    @Test("takes the first paragraph after the title")
    func firstParagraphAfterTitle() {
        let readme = """
        # SuperKit

        A networking layer for people who hate networking layers.

        ## Installation
        """
        #expect(READMELeadExtractor.lead(from: readme)
            == "A networking layer for people who hate networking layers.")
    }

    @Test("skips badge lines and joins wrapped paragraph lines")
    func skipsBadgesAndJoinsWrappedLines() {
        let readme = """
        # SuperKit

        [![CI](https://example.com/badge.svg)](https://example.com)
        ![coverage](https://example.com/cov.svg)

        A networking layer for people
        who hate networking layers.
        """
        #expect(READMELeadExtractor.lead(from: readme)
            == "A networking layer for people who hate networking layers.")
    }

    @Test("returns nil when the README has only headings and badges")
    func nilWhenNoProse() {
        let readme = """
        # SuperKit

        [![CI](https://example.com/badge.svg)](https://example.com)

        ## Installation

        ### Usage
        """
        #expect(READMELeadExtractor.lead(from: readme) == nil)
    }

    @Test("returns nil for empty content")
    func nilWhenEmpty() {
        #expect(READMELeadExtractor.lead(from: "") == nil)
        #expect(READMELeadExtractor.lead(from: "   \n\n  ") == nil)
    }

    @Test("skips HTML comments and image-only lines")
    func skipsCommentsAndImages() {
        let readme = """
        <!-- markdownlint-disable -->
        # SuperKit
        <img src="logo.png" width="200">

        The one-stop shop for networking.
        """
        #expect(READMELeadExtractor.lead(from: readme) == "The one-stop shop for networking.")
    }

    @Test("long leads truncate at a word boundary with an ellipsis")
    func truncatesAtWordBoundary() {
        let word = "abcdefghi" // 9 chars + space = 10 per repeat
        let readme = "# T\n\n" + Array(repeating: word, count: 40).joined(separator: " ")
        let lead = READMELeadExtractor.lead(from: readme)
        let unwrapped = lead ?? ""
        #expect(unwrapped.count <= 240)
        #expect(unwrapped.hasSuffix("…"))
        // Never cut mid-word: dropping the ellipsis leaves whole words only.
        let body = String(unwrapped.dropLast(1)).trimmingCharacters(in: .whitespaces)
        #expect(body.split(separator: " ").allSatisfy { $0 == Substring(word) })
    }

    @Test("markdown emphasis and links are stripped from the lead")
    func stripsInlineMarkdown() {
        let readme = """
        # T

        A **fast** parser built on [SwiftSyntax](https://github.com/apple/swift-syntax).
        """
        #expect(READMELeadExtractor.lead(from: readme)
            == "A fast parser built on SwiftSyntax.")
    }
}
