import Foundation
import QualityGateCore
import Testing
@testable import DocLinter

/// Properties for the parser and comparator shapes in `doc-lint`'s diagnostic reader.
///
/// These parse DocC's output, which this project does not control and which has
/// already changed shape once underneath it: the reader recognised two older
/// location formats and not the current `-->` continuation, dropped the location, and
/// then *recovered* it by pairing findings to candidate signatures positionally. With
/// one candidate that guesses right by luck; with eight, every guess missed and three
/// investigations went to files whose documentation was correct.
///
/// The properties below are chosen against that history: they assert that nothing is
/// invented, that a recovered value occurs in the input, and that unparseable input
/// yields *nothing* rather than something plausible.
@Suite("DocLinter parser properties")
struct DocLinterParserPropertyTests {

    private struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    private func pick<T>(_ options: [T], _ rng: inout Seeded) -> T {
        options[Int(rng.next() % UInt64(options.count))]
    }

    // MARK: - extractParameterName

    /// **Parser.** A recovered parameter name is a name that appears in the message,
    /// quoted as DocC quotes it. Nothing is invented.
    @Test("A recovered parameter name occurs in the message")
    func parameterNameComesFromTheMessage() {
        var rng = Seeded(seed: 20_260_815)
        let names = ["seed", "count", "rosters", "x", "confidenceLevel", "n2"]
        for _ in 0..<200 {
            let name = pick(names, &rng)
            let message = "Parameter '\(name)' is missing documentation"
            let recovered = DocLinter.extractParameterName(from: message)
            #expect(recovered == name)
            if let recovered { #expect(message.contains("'\(recovered)'")) }
        }
    }

    /// **Parser.** A message with no parameter reference yields `nil`, not a guess.
    ///
    /// This is the property that matters given the history: the failure was not a
    /// wrong regex, it was *inventing* a location once the regex missed.
    @Test("A message without a parameter reference yields nil")
    func unrelatedMessagesYieldNil() {
        var rng = Seeded(seed: 4_242)
        let fragments = ["Parameter", "is missing documentation", "'", "warning:",
                         "--> file.swift:1:1", "Symbol", "doesn't exist at"]
        for _ in 0..<300 {
            let message = (0..<Int(rng.next() % 6))
                .map { _ in pick(fragments, &rng) }
                .joined(separator: " ")
            // Only a quoted word after `Parameter` is a parameter reference.
            if DocLinter.extractParameterName(from: message) == nil { continue }
            #expect(message.contains("Parameter '"), "invented a name from: \(message)")
        }
    }

    // MARK: - extractSymbolReference

    /// **Parser.** Both halves of a symbol reference come from the message, and the
    /// context path keeps its leading slash — the form DocC emits and the form the
    /// repair has to be written in.
    @Test("A symbol reference's parts occur in the message")
    func symbolReferencePartsComeFromTheMessage() {
        var rng = Seeded(seed: 77)
        let symbols = ["Result", "StressFlip", "FlipDetector", "capture"]
        let paths = ["/QualityGateCore/GitProvenance", "/TestRunner", "/A/B/C"]
        for _ in 0..<200 {
            let symbol = pick(symbols, &rng)
            let path = pick(paths, &rng)
            let message = "'\(symbol)' doesn't exist at '\(path)'"
            guard let reference = DocLinter.extractSymbolReference(from: message) else {
                Issue.record("failed to parse: \(message)"); continue
            }
            #expect(message.contains(reference.symbol))
            #expect(message.contains(reference.contextPath))
            #expect(reference.contextPath.hasPrefix("/"))
        }
    }

    /// **Parser.** Arbitrary text never yields a symbol reference it did not contain.
    @Test("Arbitrary text yields no invented symbol reference")
    func noInventedSymbolReference() {
        var rng = Seeded(seed: 909)
        let fragments = ["'", "doesn't exist at", "/", "Foo", "warning:", "", "''"]
        for _ in 0..<400 {
            let message = (0..<Int(rng.next() % 8))
                .map { _ in pick(fragments, &rng) }
                .joined(separator: " ")
            guard let reference = DocLinter.extractSymbolReference(from: message) else { continue }
            #expect(message.contains(reference.symbol))
            #expect(message.contains(reference.contextPath))
        }
    }

    // MARK: - parseSeverity

    /// **Parser, total function.** Every input maps to a severity, and the mapping is
    /// case-insensitive — DocC has emitted both `warning` and `Warning`.
    @Test("Severity parsing is total and case-insensitive")
    func severityIsTotalAndCaseInsensitive() {
        for (text, expected) in [("error", Diagnostic.Severity.error),
                                 ("warning", .warning), ("note", .note)] {
            for variant in [text, text.uppercased(), text.capitalized] {
                #expect(DocLinter.parseSeverity(variant) == expected, "variant: \(variant)")
            }
        }
    }

    /// **Parser.** An unrecognised severity degrades to `.warning` rather than being
    /// dropped. A dropped diagnostic is a finding the reader never sees.
    @Test("An unknown severity degrades to warning, never to nothing")
    func unknownSeverityDegrades() {
        var rng = Seeded(seed: 31)
        let noise = ["fatal", "", "ERROR!", "remark", "info", "🙂"]
        for _ in 0..<100 {
            let text = pick(noise, &rng)
            guard !["error", "warning", "note"].contains(text.lowercased()) else { continue }
            #expect(DocLinter.parseSeverity(text) == .warning, "text: \(text)")
        }
    }

    // MARK: - The whole-output parser

    /// **Parser.** Every diagnostic recovered from DocC's output carries a message
    /// that occurred in that output. This is the invariant the positional-pairing bug
    /// violated: it produced diagnostics whose *locations* were assembled from a
    /// different ordering entirely.
    @Test("Every parsed diagnostic's message occurs in the output")
    func parsedDiagnosticsComeFromTheOutput() {
        var rng = Seeded(seed: 5_150)
        let messages = ["Parameter 'seed' is missing documentation",
                        "'Result' doesn't exist at '/Core/GitProvenance'",
                        "unresolved reference"]
        for _ in 0..<60 {
            let lines = (0..<(1 + Int(rng.next() % 5))).map { _ -> String in
                let severity = pick(["warning", "error", "note"], &rng)
                return "\(severity): \(pick(messages, &rng))"
            }
            let output = lines.joined(separator: "\n")
            for diagnostic in DocLinter.parseDocCOutput(output) {
                let core = diagnostic.message
                    .replacingOccurrences(of: "warning: ", with: "")
                    .replacingOccurrences(of: "error: ", with: "")
                #expect(output.contains(core) || output.contains(diagnostic.message),
                        "invented message: \(diagnostic.message)")
            }
        }
    }

    /// **Parser.** Empty or unparseable output yields no diagnostics — and, critically,
    /// does not yield a *pass*. `doc-lint` reports coverage separately for exactly this
    /// reason; the parser's own contract is only that it invents nothing.
    @Test("Unparseable output yields no diagnostics")
    func unparseableOutputYieldsNothing() {
        for output in ["", "\n\n", "Build complete!", "   "] {
            #expect(DocLinter.parseDocCOutput(output).isEmpty, "output: \(output.debugDescription)")
        }
    }
}
