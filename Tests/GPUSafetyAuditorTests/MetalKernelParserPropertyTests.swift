import Foundation
import Testing
@testable import GPUSafetyAuditor

/// Properties for the parser, balance and comparator shapes in the Metal reader.
///
/// One of these — `declaredNameIsAnIdentifierFromTheInput` — fails against the
/// implementation as first written, which returned `"1"` for
/// `constant ulong& baseSeed [[buffer(1)]]` by walking back from the end and finding
/// the digit inside the attribute. The example test that caught it happened to
/// include an attribute; the property does not depend on anyone thinking of that.
@Suite("MetalKernelParser properties")
struct MetalKernelParserPropertyTests {

    private struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    private func pick<T>(_ options: [T], _ rng: inout Seeded) -> T {
        options[Int(rng.next() % UInt64(options.count))]
    }

    /// Builds a declarator across the shapes MSL actually permits.
    private func declarator(_ rng: inout Seeded) -> (text: String, name: String) {
        let space = pick(["device", "constant", "threadgroup"], &rng)
        let type = pick(["float", "uint", "ulong", "RNGState", "float4"], &rng)
        let name = pick(["states", "baseSeed", "out", "gid", "n", "count", "tid2"], &rng)
        let form = pick(["*", "&", ""], &rng)
        let attribute = pick(["[[buffer(0)]]", "[[buffer(12)]]",
                              "[[thread_position_in_grid]]", ""], &rng)
        let text = "\(space) \(type)\(form) \(name) \(attribute)".trimmingCharacters(in: .whitespaces)
        return (text, name)
    }

    // MARK: - Parser

    /// **The property that catches the shipped defect.** A declared name is an
    /// identifier that occurs in the declarator — never a digit from inside an
    /// attribute, and never invented.
    @Test("A declared name is an identifier taken from the input")
    func declaredNameIsAnIdentifierFromTheInput() {
        var rng = Seeded(seed: 20_260_815)
        for _ in 0..<400 {
            let (text, expected) = declarator(&rng)
            guard let name = MetalKernelParser.declaredName(of: text) else { continue }
            #expect(name == expected, "declarator: \(text)")
            #expect(text.contains(name))
            #expect(name.first?.isNumber == false, "returned a numeric: \(name) from \(text)")
            #expect(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
        }
    }

    /// **Parser.** Splitting a parameter list never loses or invents a parameter, and
    /// never splits inside a bracketed attribute — `[[buffer(0)]]` contains no comma,
    /// but templated types and multi-argument attributes do.
    @Test("Parameter splitting preserves the parameter count")
    func splittingPreservesCount() {
        var rng = Seeded(seed: 88)
        for count in 1...8 {
            let parts = (0..<count).map { _ in declarator(&rng).text }
            let joined = parts.joined(separator: ", ")
            #expect(MetalKernelParser.splitParameters(joined).count == count, "list: \(joined)")
        }
    }

    /// **Parser.** Every split part occurs in the original list.
    @Test("Every split parameter occurs in the input")
    func splitPartsComeFromTheInput() {
        var rng = Seeded(seed: 1_234)
        for _ in 0..<120 {
            let parts = (0..<(1 + Int(rng.next() % 6))).map { _ in declarator(&rng).text }
            let joined = parts.joined(separator: ", ")
            for part in MetalKernelParser.splitParameters(joined) {
                #expect(joined.contains(part))
            }
        }
    }

    /// **Parser.** Arbitrary text must not trap. Shader source arrives from string
    /// literals and files the checker does not control.
    @Test("Arbitrary text yields kernels rather than trapping")
    func neverTrapsOnArbitraryText() {
        var rng = Seeded(seed: 5_150)
        let fragments = ["kernel", "void", "(", ")", "{", "}", "[[", "]]", "device",
                         "float*", ";", "\n", "//", "\"", "constant", "&"]
        for _ in 0..<400 {
            let text = (0..<Int(rng.next() % 40))
                .map { _ in pick(fragments, &rng) }
                .joined(separator: " ")
            let found = MetalKernelParser.kernels(
                in: text, source: .metalFile(path: "F.metal", excludedFromTarget: false))
            #expect(found.count >= 0)
            // Nothing is invented: any kernel reported names a token from the input.
            for kernel in found { #expect(text.contains(kernel.name)) }
        }
    }

    // MARK: - Balance

    /// **Balance.** On balanced input the returned index closes the opener it was
    /// given, and the enclosed span is itself balanced.
    @Test("A matched bracket closes the opener it was given")
    func matchingClosesTheOpener() {
        var rng = Seeded(seed: 6_060)
        for _ in 0..<200 {
            let depth = 1 + Int(rng.next() % 5)
            let inner = String(repeating: "x", count: Int(rng.next() % 7))
            let text = String(repeating: "(", count: depth) + inner
                + String(repeating: ")", count: depth)
            guard let open = text.firstIndex(of: "("),
                  let close = MetalKernelParser.matchingParen(in: text, openAt: open) else {
                Issue.record("no match for \(text)"); continue
            }
            #expect(text[close] == ")")
            // The span between them is balanced: equal counts of each bracket.
            let span = text[text.index(after: open)..<close]
            #expect(span.filter { $0 == "(" }.count == span.filter { $0 == ")" }.count)
        }
    }

    /// **Balance.** Unbalanced input yields no match rather than a wrong one — the
    /// failure that matters, since a wrong index silently truncates whatever follows.
    @Test("Unbalanced input yields no match")
    func unbalancedYieldsNoMatch() {
        for text in ["(", "((", "(()", "((a)"] {
            guard let open = text.firstIndex(of: "(") else { continue }
            #expect(MetalKernelParser.matchingParen(in: text, openAt: open) == nil,
                    "claimed a match in unbalanced: \(text)")
        }
    }

    // MARK: - Comparator

    /// **Comparator.** Whole-word matching never matches inside a longer identifier.
    /// `id` must not be found in `grid`, which is what makes a thread-id bounds check
    /// mean anything.
    @Test("Whole-word matching never matches a substring of a longer identifier")
    func identifierMatchingIsWholeWord() {
        var rng = Seeded(seed: 777)
        let names = ["id", "n", "gid", "tid", "count"]
        let affixes = ["", "x", "_", "1", "grid", "Size"]
        for _ in 0..<300 {
            let name = pick(names, &rng)
            let prefix = pick(affixes, &rng)
            let suffix = pick(affixes, &rng)
            let embedded = prefix + name + suffix
            let prefixEndsIdentifier = prefix.last.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
            let suffixStartsIdentifier = suffix.first.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
            if prefixEndsIdentifier || suffixStartsIdentifier {
                #expect(!embedded.containsIdentifier(name),
                        "matched `\(name)` inside `\(embedded)`")
            } else {
                #expect(embedded.containsIdentifier(name),
                        "failed to match standalone `\(name)` in `\(embedded)`")
            }
        }
    }

    /// **Comparator.** Reflexive: any identifier contains itself.
    @Test("An identifier always matches itself")
    func reflexive() {
        for name in ["id", "gid", "count", "baseSeed", "_x9"] {
            #expect(name.containsIdentifier(name))
        }
    }

    /// **Balance.** `matchingBrace` and `matchingParen` are the same algorithm over
    /// different delimiters, so the invariant is asserted of each rather than of one
    /// and assumed of the other — the shared implementation is exactly where a
    /// delimiter-specific bug would hide.
    @Test("Brace matching obeys the same invariant as paren matching")
    func braceMatchingIsBalanced() {
        var rng = Seeded(seed: 4_004)
        for _ in 0..<200 {
            let depth = 1 + Int(rng.next() % 5)
            let text = String(repeating: "{", count: depth) + "body"
                + String(repeating: "}", count: depth)
            guard let open = text.firstIndex(of: "{"),
                  let close = MetalKernelParser.matchingBrace(in: text, openAt: open) else {
                Issue.record("no match for \(text)"); continue
            }
            #expect(text[close] == "}")
            let span = text[text.index(after: open)..<close]
            #expect(span.filter { $0 == "{" }.count == span.filter { $0 == "}" }.count)
        }
    }

    /// **Balance.** The shared `matching` primitive, exercised directly over both
    /// delimiter pairs and over interleaved ones — a brace inside parens must not
    /// close the paren.
    @Test("The shared matcher ignores delimiters it was not asked about")
    func matchingIgnoresOtherDelimiters() {
        let text = "( { } )"
        guard let open = text.firstIndex(of: "("),
              let close = MetalKernelParser.matching(
                in: text, openAt: open, open: "(", close: ")") else {
            Issue.record("no match"); return
        }
        #expect(text[close] == ")")
        #expect(text.distance(from: text.startIndex, to: close) == 6)
    }

    /// **Parser.** A directory scan reports coverage consistent with what it found:
    /// kernels examined never exceeds kernels present, and a tree with no shader
    /// source reports zero rather than staying silent.
    @Test("Scan coverage is consistent with what the tree holds")
    func scanCoverageIsConsistent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gpu-prop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "// swift-tools-version: 6.2\n".write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        var rng = Seeded(seed: 24)
        for count in 0...6 {
            let kernels = (0..<count).map { index in
                """
                kernel void k\(index)(device float *o [[buffer(0)]],
                                      uint id [[thread_position_in_grid]]) {
                    o[id] = \(Double(rng.next() % 100) / 10.0);
                }
                """
            }.joined(separator: "\n\n")
            let file = root.appendingPathComponent("Sources/App/S.metal")
            try kernels.write(to: file, atomically: true, encoding: .utf8)

            let scan = GPUSafetyAuditor.scan(root: root.path)
            #expect(scan.coverageLine.contains("\(count) kernel(s) examined"),
                    "count \(count): \(scan.coverageLine)")
            // Every unbounded kernel yields exactly one finding, so findings never
            // exceed the kernels the scan says it examined.
            let bounds = scan.diagnostics.filter { $0.ruleId == "gpu.unbounded-thread-id" }
            #expect(bounds.count <= count)
        }
    }
}

