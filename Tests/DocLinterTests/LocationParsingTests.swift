import Foundation
import Testing
@testable import DocLinter
@testable import QualityGateCore

/// DocC's diagnostics must be reported where DocC says they are.
///
/// A wrong file path is not a smaller version of a missing one. It spends a reader's attention in
/// the wrong place, and it does so most confidently when there are many candidates — which is
/// when the codebase is largest. In the case that prompted this it also inverted the conclusion:
/// three separate investigations went to files whose documentation was correct, and the natural
/// reading of "correct documentation is being flagged" is *the checker is broken*, which was the
/// opposite of the truth. The checker was right; only its address was wrong.
@Suite("Doc Lint: location parsing")
struct LocationParsingTests {

    @Test("A `-->` continuation carries the location, and it is used")
    func continuationIsParsed() throws {
        // Swift 6.4's DocC puts the message on one line and the location on the next. Neither
        // of the two supported shapes matched it, so every location was dropped and then
        // guessed. Measured on the run that found this: 0 diagnostics used the inline format.
        let diagnostics = DocLinter.parseDocCOutput("""
        warning: Parameter 'seed' is missing documentation
           --> ../Portfolio/PortfolioUtilities.swift:103:54-103:54
        """)

        let finding = try #require(diagnostics.first)
        #expect(finding.lineNumber == 103)
        #expect(finding.columnNumber == 54)
        #expect(finding.filePath?.hasSuffix("PortfolioUtilities.swift") == true)
    }

    @Test("A continuation with no end range still matches")
    func continuationWithoutRange() throws {
        let diagnostics = DocLinter.parseDocCOutput("""
        warning: Something
           --> ../A/B.swift:10:5
        """)

        #expect(try #require(diagnostics.first).lineNumber == 10)
    }

    @Test("A blank line between message and location does not break the pairing")
    func blankLineBetween() throws {
        let diagnostics = DocLinter.parseDocCOutput("""
        warning: Something

           --> ../A/B.swift:42:7-42:7
        """)

        #expect(try #require(diagnostics.first).lineNumber == 42)
    }

    @Test("The old inline format still parses, for older toolchains")
    func inlineFormatStillWorks() throws {
        let diagnostics = DocLinter.parseDocCOutput(
            "/x/Sources/Foo.swift:12:3: warning: No documentation for 'bar'")

        let finding = try #require(diagnostics.first)
        #expect(finding.lineNumber == 12)
        #expect(finding.columnNumber == 3)
    }

    @Test("A message with no continuation gets no location — and no guess")
    func noContinuationMeansNoLocation() throws {
        // The rule that matters: a diagnostic with no location is a smaller failure than one
        // with a wrong location, and must be preferred whenever the answer is not unique.
        let diagnostics = DocLinter.parseDocCOutput("warning: 'MyType' doesn't exist at '/M/T'")

        let finding = try #require(diagnostics.first)
        #expect(finding.filePath == nil)
        #expect(finding.lineNumber == nil || finding.lineNumber == 0)
    }

    @Test("Each diagnostic takes its own location, not the one at its index")
    func locationsAreNotPairedByIndex() throws {
        // The dangerous fault. `entries` follows DocC's emission order and the recovered
        // signature list follows file-traversal order; nothing aligns them. With one `seed:`
        // parameter in a package the guess lands by luck. With eight, every guess missed.
        let diagnostics = DocLinter.parseDocCOutput("""
        warning: Parameter 'seed' is missing documentation
           --> ../Portfolio/PortfolioUtilities.swift:103:54-103:54
        warning: Parameter 'seed' is missing documentation
           --> ../Statistics/bernoulliTrial.swift:16:5-16:5
        """)

        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].filePath?.hasSuffix("PortfolioUtilities.swift") == true)
        #expect(diagnostics[0].lineNumber == 103)
        #expect(diagnostics[1].filePath?.hasSuffix("bernoulliTrial.swift") == true)
        #expect(diagnostics[1].lineNumber == 16)
    }

    @Test("Source-context lines below a continuation are not mistaken for diagnostics")
    func sourceContextIsIgnored() {
        // DocC prints the offending lines under the location, with `|` gutters and a
        // `╰─suggestion:` marker. None of it is a finding.
        let diagnostics = DocLinter.parseDocCOutput("""
        warning: Parameter 'seed' is missing documentation
           --> ../A/B.swift:103:54-103:54
        101 | ///   - size: Number of assets (matrix dimension)
        102 | ///   - avgCorrelation: Average correlation between assets
        103 + ///   - volatility: Asset volatility range (min, max)
            |                    ╰─suggestion: Document 'seed' parameter
        """)

        #expect(diagnostics.count == 1)
    }
}
