import Foundation
import Testing
@testable import DocCodeAuditor
import QualityGateCore

/// Assembly is where every wrong answer in this auditor's history came from.
///
/// A fence that is never extracted is a block that is never checked, and the report says
/// "passed" either way — so the tests below are as much about *coverage* as about
/// correctness. Each one corresponds to a defect that shipped in the prototype.
@Suite("Article Assembly")
struct ArticleAssemblyTests {

    // MARK: - Discovery

    @Test("A fence indented inside a list item is found and checked")
    func indentedFenceIsChecked() {
        // The prototype matched `"```swift"` at column 0, so fences nested in list items were
        // silently dropped. Six articles passed with unchecked blocks, and those blocks held
        // real API drift. Match on the trimmed line.
        let markdown = """
        # Guide

        1. First, build the model:

           ```swift
           let model = 1
           ```

        2. Then read it:

           ```swift
           print(model)
           ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.fencesFound == 2)
        #expect(assembled.fencesChecked == 2)
        #expect(assembled.source.contains("let model = 1"))
        #expect(assembled.source.contains("print(model)"))
    }

    @Test("The fence's own indentation is stripped from the assembled program")
    func indentationIsStripped() {
        let markdown = """
        - Example:

          ```swift
          let x = 1
              let y = 2
          ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.source.contains("\nlet x = 1\n"))
        // Deeper indentation inside the block survives; only the fence's own indent goes.
        #expect(assembled.source.contains("\n    let y = 2\n"))
    }

    @Test("A fence whose language merely starts with 'swift' is not Swift")
    func swiftuiFenceIsNotSwift() {
        // `hasPrefix("```swift")` also matches ```swiftui, ```swift-output and friends.
        // Compiling those produces findings about a language the block never claimed.
        let markdown = """
        ```swiftui
        not code
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.fencesFound == 0)
        #expect(assembled.fencesChecked == 0)
    }

    @Test("Fence language matching is case-insensitive and tolerates attributes")
    func languageMatchingIsLenient() {
        let markdown = """
        ```Swift
        let a = 1
        ```

        ```swift title="Example"
        let b = 2
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.fencesFound == 2)
        #expect(assembled.fencesChecked == 2)
    }

    @Test("Non-Swift fences are ignored by language, not by guesswork")
    func nonSwiftFencesIgnored() {
        let markdown = """
        ```bash
        swift build
        ```

        ```json
        { "a": 1 }
        ```

        ```
        plain output
        ```

        ```swift
        let a = 1
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.fencesFound == 1)
        #expect(assembled.fencesChecked == 1)
    }

    // MARK: - The one opt-out

    @Test("An illustrative block is skipped, and counted")
    func illustrativeIsSkippedAndCounted() {
        let markdown = """
        <!-- docs:illustrative -->
        ```swift
        func signature(only:) -> Never
        ```

        ```swift
        let real = 1
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.fencesFound == 2)
        #expect(assembled.fencesChecked == 1)
        #expect(assembled.fencesExempt == 1)
        #expect(!assembled.source.contains("signature(only:)"))
    }

    @Test("The illustrative marker survives blank lines before its fence")
    func illustrativeMarkerSurvivesBlankLines() {
        // The prototype cleared the pending marker on any line that was not a fence, so a
        // blank line between the comment and the block silently un-exempted it — and then
        // reported the resulting errors as documentation defects.
        let markdown = """
        <!-- docs:illustrative -->

        ```swift
        func signature(only:) -> Never
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.fencesExempt == 1)
        #expect(assembled.fencesChecked == 0)
    }

    @Test("The marker exempts only the fence that follows it")
    func markerAppliesToOneFence() {
        let markdown = """
        <!-- docs:illustrative -->
        ```swift
        nonsense !!!
        ```

        ```swift
        let real = 1
        ```

        ```swift
        print(real)
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.fencesExempt == 1)
        #expect(assembled.fencesChecked == 2)
        #expect(!assembled.source.contains("nonsense"))
    }

    // MARK: - Line mapping

    @Test("A diagnostic maps back to the article's line, not the temp file's")
    func mapsBackToArticleLine() throws {
        // Article lines:  1 `# Title`, 2 blank, 3 fence, 4 `let a = 1`, 5 `let b = 2`, 6 fence
        let markdown = """
        # Title

        ```swift
        let a = 1
        let b = 2
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: ["Foundation"])
        let firstBodyLine = assembled.source.lines.firstIndex(of: "let a = 1").map { $0 + 1 }
        let secondBodyLine = assembled.source.lines.firstIndex(of: "let b = 2").map { $0 + 1 }
        #expect(assembled.articleLine(forAssembledLine: try #require(firstBodyLine)) == 4)
        #expect(assembled.articleLine(forAssembledLine: try #require(secondBodyLine)) == 5)
    }

    @Test("Line mapping is exact across two blocks separated by prose")
    func mapsAcrossBlocks() throws {
        let markdown = """
        ```swift
        let a = 1
        ```

        Some prose that pushes the second block down the article.

        More prose.

        ```swift
        let b = 2
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        let second = assembled.source.lines.firstIndex(of: "let b = 2").map { $0 + 1 }
        #expect(assembled.articleLine(forAssembledLine: try #require(second)) == 10)
    }

    @Test("Imports are commented, never deleted, so offsets stay exact")
    func importsAreCommentedNotRemoved() throws {
        // Deleting a line shifts every diagnostic after it. Two of five reported locations
        // were off by one until imports were commented instead of stripped.
        let markdown = """
        ```swift
        import Foundation
        let a = 1
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: ["Foundation"])
        #expect(assembled.source.contains("// import Foundation"))
        let line = assembled.source.lines.firstIndex(of: "let a = 1").map { $0 + 1 }
        #expect(assembled.articleLine(forAssembledLine: try #require(line)) == 3)
    }

    @Test("An assembled line in the preamble maps to article line 1, not to itself")
    func preambleMapsToLineOne() {
        let assembled = ArticleAssembler.assemble("```swift\nlet a = 1\n```", imports: ["Foundation"])
        #expect(assembled.articleLine(forAssembledLine: 1) == 1)
    }

    // MARK: - Coverage arithmetic

    @Test("Found always equals checked plus exempt")
    func coverageAddsUp() {
        let markdown = """
        ```swift
        let a = 1
        ```
        <!-- docs:illustrative -->
        ```swift
        ...
        ```
        ```bash
        echo hi
        ```
        """
        let assembled = ArticleAssembler.assemble(markdown, imports: [])
        #expect(assembled.fencesFound == assembled.fencesChecked + assembled.fencesExempt)
        #expect(assembled.fencesFound == 2)
    }
}
