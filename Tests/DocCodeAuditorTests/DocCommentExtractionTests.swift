import Foundation
import Testing
@testable import DocCodeAuditor

/// Extraction is the whole argument for `doc-comment-code` being an AST checker.
///
/// A line regex over `Sources/` reports 21 swift doc fences in this repository. The strict
/// count is 20, and the difference is a single inline code span in prose — in
/// `ArticleAssembler.swift`, in the sentence that explains why the illustrative marker is an
/// HTML comment. A regex extractor would try to compile the rest of that doc comment and
/// report the errors as documentation defects, in the file that documents the rule.
///
/// Every "must not flag" case below is one of those: a place where the text of a line looks
/// like a fence and the syntax tree says otherwise.
@Suite("Doc Comment Extraction")
struct DocCommentExtractionTests {

    // MARK: - Finding fences

    @Test("A swift fence in a /// run is found, with the file line of its opener")
    func swiftFenceIsFound() {
        let source = """
        import Foundation

        /// A documented type.
        ///
        /// ```swift
        /// let value = Documented()
        /// ```
        public struct Documented {}
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Documented.swift")
        #expect(fences.count == 1)
        #expect(fences.first?.isSwift == true)
        // The opener `/// ```swift` is line 5 of the file.
        #expect(fences.first?.openLine == 5)
        #expect(fences.first?.body == ["let value = Documented()"])
        #expect(fences.first?.declarationName == "Documented")
    }

    @Test("Two fences in one doc comment are two independent units")
    func twoFencesInOneDocCommentAreTwoUnits() {
        // HIGAuditor.swift, reduced. One `///` run, two fences: a usage example and a
        // fragment of the *reader's* code. They share a doc comment and nothing else, and
        // both binding `result` is not a defect. Under any per-doc-comment or per-file
        // compilation unit this fixture fails, which is what makes decision 4 falsifiable.
        let source = """
        /// An auditor.
        ///
        /// ```swift
        /// let result = 1
        /// ```
        ///
        /// ## Exemptions
        ///
        /// ```swift
        /// let result = 2
        /// ```
        public struct Auditor {}
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Auditor.swift")
        #expect(fences.count == 2)
        #expect(fences.map(\.openLine) == [3, 9])
        #expect(fences.map(\.body) == [["let result = 1"], ["let result = 2"]])
    }

    @Test("A fence that is not the first in its comment still reports its own line")
    func laterFenceKeepsItsOwnLine() {
        let source = """
        /// Docs.
        ///
        /// ```yaml
        /// key: value
        /// ```
        ///
        /// ```swift
        /// let x = 1
        /// ```
        public func documented() {}
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "F.swift")
        #expect(fences.count == 2)
        #expect(fences.last?.openLine == 7)
        #expect(fences.last?.isSwift == true)
    }

    @Test("A doc comment on a nested, indented declaration keeps file line numbers")
    func indentedDeclarationKeepsFileLines() {
        let source = """
        public enum Outer {

            /// An inner value.
            ///
            /// ```swift
            /// let inner = Outer.inner
            /// ```
            public static let inner = 1
        }
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Outer.swift")
        #expect(fences.count == 1)
        #expect(fences.first?.openLine == 5)
        // The `///` prefix is stripped, not the file's indentation: the body is file-scope
        // Swift, and the column shift is the known cost recorded in the proposal.
        #expect(fences.first?.body == ["let inner = Outer.inner"])
    }

    @Test("A fence indented inside a doc-comment list item is dedented")
    func indentedFenceInsideCommentIsDedented() {
        let source = """
        /// Steps:
        ///
        /// 1. Build it:
        ///
        ///    ```swift
        ///    let built = 1
        ///    ```
        public func steps() {}
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Steps.swift")
        #expect(fences.count == 1)
        #expect(fences.first?.body == ["let built = 1"])
    }

    // MARK: - Must not flag

    @Test("An inline code span containing a fence in prose is not a fence")
    func inlineCodeSpanIsNotAFence() {
        // `ArticleAssembler.swift:66` verbatim in shape. This is the twenty-first fence a
        // line regex reports and the AST does not, and the only test that distinguishes the
        // two extractors.
        let source = """
        /// The one opt-out.
        ///
        /// Written as an HTML comment rather than a fence info string because DocC passes an
        /// info string through as the block's *language identifier*: ` ```swift,illustrative `
        /// renders as an unknown language and silently costs syntax highlighting.
        public let illustrativeMarker = "<!-- docs:illustrative -->"
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "ArticleAssembler.swift")
        #expect(fences.isEmpty)
    }

    @Test("A /// sequence inside a multi-line string literal is not a doc comment")
    func tripleSlashInAStringLiteralIsNotADocComment() {
        // Token text, not trivia. `Tests/DocCodeAuditorTests/` is full of markdown fences in
        // string fixtures, and the AST cannot confuse them for documentation.
        let source = #"""
        let fixture = """
        /// ```swift
        /// let notDocumentation = 1
        /// ```
        """
        """#
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Fixture.swift")
        #expect(fences.isEmpty)
    }

    @Test("An ordinary // comment containing a fence is not a doc comment")
    func ordinaryLineCommentIsNotADocComment() {
        let source = """
        // ```swift
        // let scratch = 1
        // ```
        public let value = 1
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Scratch.swift")
        #expect(fences.isEmpty)
    }

    @Test("```swiftui and ```swift-output are not Swift; ```swift title=… is")
    func languageTokenRuleIsInherited() {
        // Earned by a bug that shipped once: `hasPrefix("```swift")` also matches ```swiftui,
        // and compiling those produces findings about a language the block never claimed.
        let source = """
        /// Docs.
        ///
        /// ```swiftui
        /// NavigationStack { UtilityView() }
        /// ```
        ///
        /// ```swift-output
        /// 42
        /// ```
        ///
        /// ```swift title="Example"
        /// let tagged = 1
        /// ```
        public func documented() {}
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Tagged.swift")
        #expect(fences.count == 3)
        #expect(fences.map(\.isSwift) == [false, false, true])
        #expect(fences.map(\.language) == ["swiftui", "swift-output", "swift"])
    }

    @Test("A nested fence inside a shell transcript is not a fence of its own")
    func nestedFenceIsConsumedByItsOuterBlock() {
        let source = """
        /// Docs.
        ///
        /// ````bash
        /// $ cat File.swift
        /// ```swift
        /// let inner = 1
        /// ```
        /// ````
        public func documented() {}
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Shell.swift")
        #expect(fences.count == 1)
        #expect(fences.first?.isSwift == false)
    }

    // MARK: - The illustrative marker

    @Test("<!-- docs:illustrative --> exempts the fence that follows it")
    func markerExemptsTheFollowingFence() {
        let source = """
        /// Docs.
        ///
        /// <!-- docs:illustrative -->
        /// ```swift
        /// let x = someSymbolFromAnotherPackage()
        /// ```
        public func documented() {}
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Exempt.swift")
        #expect(fences.count == 1)
        #expect(fences.first?.isExempt == true)
    }

    @Test("The marker survives a blank /// line and nothing else")
    func markerSurvivesABlankDocLine() {
        // The exact defect `ArticleAssembler` shipped once: a marker separated from its block
        // by a blank line was dropped, and the block it exempted was reported as broken.
        let separated = """
        /// <!-- docs:illustrative -->
        ///
        /// ```swift
        /// nonsense
        /// ```
        public func a() {}
        """
        #expect(DocCommentFenceExtractor.fences(in: separated, path: "A.swift").first?.isExempt == true)

        let interrupted = """
        /// <!-- docs:illustrative -->
        ///
        /// But this prose clears it.
        ///
        /// ```swift
        /// let x = 1
        /// ```
        public func b() {}
        """
        #expect(DocCommentFenceExtractor.fences(in: interrupted, path: "B.swift").first?.isExempt == false)
    }

    @Test("A marker in one doc comment does not leak into the next")
    func markerDoesNotLeakAcrossDocComments() {
        let source = """
        /// <!-- docs:illustrative -->
        public func a() {}

        /// ```swift
        /// let x = 1
        /// ```
        public func b() {}
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Leak.swift")
        #expect(fences.count == 1)
        #expect(fences.first?.isExempt == false)
    }

    // MARK: - Block comments

    @Test("A /** */ doc comment carrying a fence is extracted")
    func blockCommentFenceIsExtracted() {
        // This path has no corpus anywhere in the package — zero `/** */` doc comments exist
        // — so these fixtures are the only thing standing behind it.
        let source = """
        /**
         A documented function.

         ```swift
         let value = documented()
         ```
         */
        public func documented() -> Int { 1 }
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Block.swift")
        #expect(fences.count == 1)
        #expect(fences.first?.isSwift == true)
        #expect(fences.first?.openLine == 4)
        #expect(fences.first?.body == ["let value = documented()"])
    }

    @Test("A /** */ doc comment with * continuation markers is stripped correctly")
    func blockCommentContinuationMarkersAreStripped() {
        let source = """
        /**
         * A documented function.
         *
         * ```swift
         * let product = 6 * 7
         * ```
         */
        public func documented() {}
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Stars.swift")
        #expect(fences.count == 1)
        #expect(fences.first?.openLine == 4)
        #expect(fences.first?.body == ["let product = 6 * 7"])
    }

    @Test("A /** */ body line that itself begins with * survives the strip")
    func blockCommentBodyLineBeginningWithStarSurvives() {
        // The most likely first bug on this path: the continuation-marker strip eating a
        // body line's own leading `*`. Exactly one marker comes off per line.
        let source = """
        /**
         * ```swift
         * *thing = 1
         * ```
         */
        public func documented() {}
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "Deref.swift")
        #expect(fences.first?.body == ["*thing = 1"])
    }

    @Test("A /** */ doc comment without continuation markers keeps a leading *")
    func blockCommentWithoutMarkersKeepsLeadingStar() {
        // No line between the delimiters starts with `*`, so nothing is a continuation
        // marker and nothing may be stripped.
        let source = """
        /**
         ```swift
         *thing = 1
         ```
         */
        public func documented() {}
        """
        let fences = DocCommentFenceExtractor.fences(in: source, path: "NoMarkers.swift")
        #expect(fences.first?.body == ["*thing = 1"])
    }

    // MARK: - Census

    @Test("The coverage line reports found, checked, exempt and not-Swift")
    func censusArithmetic() {
        let source = """
        /// Docs.
        ///
        /// ```swift
        /// let a = 1
        /// ```
        ///
        /// ```swift
        /// let b = 2
        /// ```
        ///
        /// <!-- docs:illustrative -->
        /// ```swift
        /// nonsense
        /// ```
        ///
        /// ```yaml
        /// key: value
        /// ```
        ///
        /// ```
        /// a diagram
        /// ```
        public func documented() {}
        """
        let census = DocCommentFenceExtractor.census(in: source, path: "Census.swift")
        #expect(census.found == 5)
        #expect(census.checked == 2)
        #expect(census.exempt == 1)
        #expect(census.notSwift == 2)
        // Assert the arithmetic, not just the pass: a gate that under-reports its own
        // coverage is indistinguishable from a gate that passes.
        #expect(census.coverageMessage.hasPrefix("5 doc fences: 2 checked, 1 exempt, 2 not Swift"))
        #expect(census.foreignLanguages == ["(untagged)", "yaml"])
    }

    @Test("A file with no doc fences reports an empty census")
    func emptyCensus() {
        let source = """
        /// Just prose, no example.
        public func documented() {}
        """
        let census = DocCommentFenceExtractor.census(in: source, path: "Empty.swift")
        #expect(census.found == 0)
        #expect(census.fences.isEmpty)
    }
}
