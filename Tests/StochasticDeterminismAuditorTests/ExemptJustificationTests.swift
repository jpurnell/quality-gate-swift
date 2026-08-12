import Foundation
import Testing
import SwiftParser
import SwiftSyntax
@testable import QualityGateCore
@testable import StochasticDeterminismAuditor

/// A suppression marker must say why.
///
/// The module already decided this for its newest rule — `stochastic-unseeded-test-call` takes
/// `// Justification: …` and validates it — and never went back for its oldest one. This is
/// that gap closed, not a new convention.
@Suite("Stochastic Exempt Justification")
struct ExemptJustificationTests {

    // MARK: - The parse, on its own

    @Test("Trailing prose is a justification")
    func proseIsAJustification() throws {
        let marker = try #require(ExemptMarker.parse(
            line: "var g = SystemRandomNumberGenerator() // stochastic:exempt — the documented unseeded path; pass `seed:` for reproducibility",
            keyword: "stochastic:exempt"))

        #expect(marker.hasJustification)
    }

    @Test("A bare marker is not")
    func bareMarkerIsNotAJustification() throws {
        let marker = try #require(ExemptMarker.parse(
            line: "point.append(Double.random(in: lower...upper)) // stochastic:exempt",
            keyword: "stochastic:exempt"))

        #expect(!marker.hasJustification)
    }

    @Test("Trailing whitespace is not a reason")
    func whitespaceIsNotAJustification() throws {
        let marker = try #require(ExemptMarker.parse(
            line: "let x = Double.random(in: 0...1) // stochastic:exempt   ",
            keyword: "stochastic:exempt"))

        #expect(!marker.hasJustification)
    }

    @Test("A dash is not a reason")
    func punctuationIsNotAJustification() throws {
        let marker = try #require(ExemptMarker.parse(
            line: "let x = Double.random(in: 0...1) // stochastic:exempt —",
            keyword: "stochastic:exempt"))

        #expect(!marker.hasJustification)
    }

    @Test("One marker's reason does not satisfy another's")
    func siblingMarkerIsNotAJustification() throws {
        // `fp-safety:disable` is a different auditor's suppression. Counting it as this one's
        // explanation would let a line silence two rules while explaining neither.
        let marker = try #require(ExemptMarker.parse(
            line: "let scale = a / norm // stochastic:exempt fp-safety:disable",
            keyword: "stochastic:exempt"))

        #expect(!marker.hasJustification)
    }

    @Test("Combined markers with a real reason are accepted")
    func combinedMarkersWithProseAreAccepted() throws {
        // The real line at `UncertaintySet.swift:271`.
        let marker = try #require(ExemptMarker.parse(
            line: "let scale = Double.random(in: 0...radius) / norm // stochastic:exempt fp-safety:disable — norm > 0 from enclosing if",
            keyword: "stochastic:exempt"))

        #expect(marker.hasJustification)
    }

    @Test("A line with no marker parses to nothing")
    func noMarker() {
        #expect(ExemptMarker.parse(
            line: "let x = Double.random(in: 0...1)", keyword: "stochastic:exempt") == nil)
    }

    // MARK: - What the auditor does with it

    private func diagnose(_ source: String) -> [Diagnostic] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "test.swift", tree: tree)
        let visitor = StochasticVisitor(
            filePath: "test.swift",
            converter: converter,
            sourceLines: source.components(separatedBy: "\n"),
            flagCollectionShuffle: true,
            flagGlobalState: true,
            exemptFunctions: []
        )
        visitor.walk(tree)
        return visitor.diagnostics
    }

    @Test("A justified marker is silent — it suppresses and says why")
    func justifiedMarkerIsSilent() {
        let findings = diagnose("""
        func simulate() {
            let x = Double.random(in: 0...1) // stochastic:exempt — environmental jitter with no seeded sibling
        }
        """)

        #expect(findings.isEmpty)
    }

    @Test("A bare marker still suppresses, and reports exactly one missing justification")
    func bareMarkerReportsOnce() throws {
        // Still suppressing is the point: no gate that passes today starts failing. The marker
        // becomes *visible* rather than becoming an error.
        let findings = diagnose("""
        func simulate() {
            let x = Double.random(in: 0...1) // stochastic:exempt
        }
        """)

        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.ruleId == "stochastic.exempt-no-justification")
        #expect(finding.severity == .warning)
    }

    @Test("Two suppressed findings on one line report one missing justification, not two")
    func oneReportPerLine() {
        let findings = diagnose("""
        func simulate() {
            let pair = (Double.random(in: 0...1), Double.random(in: 0...1)) // stochastic:exempt
        }
        """)

        #expect(findings.filter { $0.ruleId == "stochastic.exempt-no-justification" }.count == 1)
    }

    @Test("The report points at the marker's own line")
    func reportIsLocated() throws {
        let findings = diagnose("""
        func simulate() {
            let a = 1
            let x = Double.random(in: 0...1) // stochastic:exempt
        }
        """)

        let finding = try #require(findings.first)
        #expect(finding.lineNumber == 3)
    }
}
