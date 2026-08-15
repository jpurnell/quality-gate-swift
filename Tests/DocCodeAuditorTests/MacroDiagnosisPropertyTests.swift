import Testing
@testable import DocCodeAuditor

/// Properties for the balance-shaped and parser-shaped functions in ``MacroDiagnosis``.
///
/// The first test here is the validation trace from `PropertyCoverage.md`: it fails
/// against the implementation as it stood before `8c521ad`, which took the first `]`
/// and so matched the bracket closing the `[Macro.Type]` annotation rather than the
/// array. The example tests written at the time all passed.
@Suite("MacroDiagnosis properties")
struct MacroDiagnosisPropertyTests {

    /// A deterministic generator. Seeded, because a property that cannot be replayed
    /// reports a failure nobody can reproduce.
    private struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    private func macroNames(count: Int, using rng: inout Seeded) -> [String] {
        let stems = ["Validated", "Positive", "Range", "Min", "Max", "NonEmpty",
                     "Variable", "Objective", "Constraint", "MCPTool", "Builder"]
        return (0..<count).map { index in
            "\(stems[Int(rng.next() % UInt64(stems.count))])\(index)Macro"
        }
    }

    /// Renders a plugin the way SwiftPM users actually write one, with the type
    /// annotation that broke the naive parser.
    private func pluginSource(registering names: [String], annotated: Bool) -> String {
        let entries = names.map { "        \($0).self," }.joined(separator: "\n")
        let annotation = annotated ? ": [Macro.Type]" : ""
        return """
            @main
            struct GeneratedPlugin: CompilerPlugin {
                let providingMacros\(annotation) = [
            \(entries)
                ]
            }
            """
    }

    // MARK: - The property that catches the shipped bug

    /// **Round-trip.** Every name rendered into `providingMacros` comes back out, for
    /// any number of entries and whether or not the type annotation is present.
    ///
    /// The annotation is the whole point. `let providingMacros: [Macro.Type] = [ … ]`
    /// contains two `[` before the array's contents, and a parser that stops at the
    /// first `]` returns an empty list while reporting success.
    @Test("Every registered macro is recovered, annotation or not")
    func registrationsRoundTrip() {
        var rng = Seeded(seed: 20_260_815)
        for iteration in 0..<120 {
            let names = macroNames(count: 1 + iteration % 12, using: &rng)
            for annotated in [true, false] {
                let source = pluginSource(registering: names, annotated: annotated)
                let recovered = MacroDiagnosis.registeredTypes(inPluginSource: source)
                #expect(recovered == names.sorted(),
                        "annotated: \(annotated), \(names.count) entries")
            }
        }
    }

    /// **Balance.** The count recovered equals the number of `.self` entries written,
    /// which is the invariant a bracket matcher owes independent of what it parses.
    @Test("Recovered count equals entries written")
    func countIsPreserved() {
        var rng = Seeded(seed: 7)
        for count in 1...25 {
            let names = macroNames(count: count, using: &rng)
            let source = pluginSource(registering: names, annotated: true)
            #expect(MacroDiagnosis.registeredTypes(inPluginSource: source).count == count)
        }
    }

    /// **Parser.** Nothing is invented: every recovered name occurs in the source.
    @Test("Every recovered name occurs in the source text")
    func namesComeFromTheInput() {
        var rng = Seeded(seed: 99)
        for _ in 0..<60 {
            let names = macroNames(count: 1 + Int(rng.next() % 9), using: &rng)
            let source = pluginSource(registering: names, annotated: true)
            for recovered in MacroDiagnosis.registeredTypes(inPluginSource: source) {
                #expect(source.contains(recovered))
            }
        }
    }

    /// **Parser.** Arbitrary input must not trap. A registration reader runs over
    /// whatever a package happens to contain, including files that are not plugins.
    @Test("Arbitrary input yields a result rather than trapping")
    func neverTrapsOnArbitraryInput() {
        var rng = Seeded(seed: 4_242)
        let fragments = ["providingMacros", "[", "]", "=", ".self", "[Macro.Type]",
                         "\"", "//", "\n", "struct", "{", "}", "Foo"]
        for _ in 0..<400 {
            let source = (0..<Int(rng.next() % 30))
                .map { _ in fragments[Int(rng.next() % UInt64(fragments.count))] }
                .joined()
            // The assertion is that this returns at all; a count is the observable proof.
            #expect(MacroDiagnosis.registeredTypes(inPluginSource: source).count >= 0)
        }
    }

    // MARK: - The diagnostic parser

    /// **Parser.** For any well-formed compiler message, the parts recovered are the
    /// parts that were written.
    @Test("A diagnostic's parts round-trip out of its message")
    func diagnosticPartsRoundTrip() {
        var rng = Seeded(seed: 31_337)
        let modules = ["XImpl", "BusinessMathMacrosImpl", "A.B.CImpl"]
        for _ in 0..<80 {
            let module = modules[Int(rng.next() % UInt64(modules.count))]
            let type = macroNames(count: 1, using: &rng)[0]
            let macro = String(type.dropLast("Macro".count))
            let message = """
                external macro implementation type '\(module).\(type)' could not be found \
                for macro '\(macro)()'; plugin for module '\(module)' not found
                """
            let parsed = MacroDiagnosis.parse(message)
            #expect(parsed?.pluginModule == module)
            #expect(parsed?.implementationType == type)
            #expect(parsed?.macroName == macro)
        }
    }

    /// **Parser.** A message that is not this diagnostic is never claimed as one.
    @Test("Unrelated messages are never parsed as macro diagnostics")
    func unrelatedMessagesAreRejected() {
        var rng = Seeded(seed: 5)
        let noise = ["cannot find 'x' in scope", "expected declaration", "",
                     "type 'A' does not conform to 'B'", "'''", "external macro"]
        for _ in 0..<200 {
            let message = (0..<Int(rng.next() % 4))
                .map { _ in noise[Int(rng.next() % UInt64(noise.count))] }
                .joined(separator: " ")
            if !message.contains("external macro implementation type") {
                #expect(MacroDiagnosis.parse(message) == nil, "claimed: \(message)")
            }
        }
    }
}
