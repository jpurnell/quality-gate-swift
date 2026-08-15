import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// Shape-bearing functions that no property-shaped test exercises.
///
/// ## Why a property and not another example
///
/// An example test asks whether the code works for the case its author thought of,
/// and the author chose the cases. Three defects in this package in one week passed
/// their example tests and are each caught by one line of invariant: a region diff
/// that reported no differences for rows in the wrong order, a registration parser
/// that returned zero because it matched the bracket closing a type annotation, and a
/// parameter reader that returned `"1"` — the digit inside `[[buffer(1)]]`.
///
/// ## What this rule refuses to do
///
/// It never reports a ratio. A suite that is 98% example-based is *correct* if its
/// shape-bearing functions are covered, and the moment a percentage is printed someone
/// will optimise it. The unit is always the function.
///
/// It never reports a regression test as a gap. A test pinned to a real artefact —
/// "this specific kernel must not be flagged, because the naive fix deadlocks it" —
/// has no property, and converting it to one destroys the thing that makes it worth
/// having.
public enum PropertyCoverage {

    /// The rule's identifier.
    public static let ruleId = "test-quality.property-coverage"

    /// A function that owes an invariant.
    public struct Candidate: Sendable, Equatable {
        /// The function's base name.
        public let name: String
        /// The shape it carries.
        public let shape: FunctionShape
        /// File it is declared in.
        public let path: String
        /// 1-indexed declaration line.
        public let line: Int
    }

    // MARK: - Source pass

    /// Every shape-bearing function in a file, plus the names it calls.
    ///
    /// - Parameters:
    ///   - source: Swift source text.
    ///   - path: The file's path, carried onto findings.
    /// - Returns: Candidates, and a map of caller to the names it calls.
    public static func candidates(
        in source: String, path: String
    ) -> (candidates: [Candidate], calls: [String: Set<String>]) {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)

        // Two passes over the same tree: the first decides whether this file parses at
        // all, because that is what makes a renderer in it a round-trip candidate.
        let survey = FunctionSurvey(converter: converter)
        survey.walk(tree)
        let fileParses = survey.functions.contains {
            FunctionShape.looksLikeParser(name: $0.name, takesText: $0.takesText)
        }

        var found: [Candidate] = []
        for function in survey.functions {
            guard let shape = FunctionShape.classify(
                name: function.name, takesText: function.takesText,
                fileAlsoParses: fileParses) else { continue }
            // A nested local function is not API and cannot be property-tested from
            // outside; `canonicalize` inside another function's body is the shape that
            // surfaced this.
            guard !function.isNested else { continue }
            found.append(Candidate(
                name: function.name, shape: shape, path: path, line: function.line))
        }
        return (found, survey.calls)
    }

    // MARK: - Test pass

    /// Symbols named inside property-shaped tests.
    ///
    /// A test is property-shaped when it is `@Test(arguments:)`, drives a seeded
    /// generator, loops a bounded range, or asserts a round-trip. An example test with
    /// a different literal is not a property.
    public static func propertyCoveredSymbols(inTestSource source: String) -> Set<String> {
        var covered: Set<String> = []
        let stripped = strippingMultilineStrings(source)
        let pattern = #"(@Test\b(\([^)]*\))?|func\s+test[A-Z_]\w*)"#
        // silent: this pattern is a compile-time constant, so a throw here is unreachable
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(stripped.startIndex..., in: stripped)
        for match in regex.matches(in: stripped, range: range) {
            guard let whole = Range(match.range, in: stripped) else { continue }
            let attribute = match.range(at: 2).location == NSNotFound
                ? "" : (Range(match.range(at: 2), in: stripped).map { String(stripped[$0]) } ?? "")
            guard let body = bracedBody(of: stripped, from: whole.upperBound) else { continue }
            guard isPropertyShaped(attribute: attribute, body: body) else { continue }
            for symbol in calledNames(in: body) { covered.insert(symbol) }
        }
        return covered
    }

    static func isPropertyShaped(attribute: String, body: String) -> Bool {
        if attribute.contains("arguments:") { return true }
        let seeded = ["Seeded", "RandomNumberGenerator", "seed:"]
        if seeded.contains(where: { body.contains($0) }) { return true }
        if body.range(of: #"for\s+\w+\s+in\s+(0\.\.[.<]\s*\d|stride\()"#,
                      options: .regularExpression) != nil { return true }
        if body.range(of: #"(decode|parse|round[Tt]rip|encode)\w*\(.*\)\s*=="#,
                      options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: - Findings

    /// Candidates with no property-shaped test naming them, directly or through one
    /// level of delegation.
    ///
    /// **The depth is fixed at one and is not configurable.** A thin wrapper's
    /// invariant is its delegate's invariant, so a property on `matchingParen`
    /// genuinely covers `matching`. Two levels already claims a property about code the
    /// test never mentions, and the count is violently sensitive to the bound —
    /// measured on this package at 76 / 35 / 23 / 16 uncovered for depths 1 / 2 / 3 / 6.
    /// A finding count that moves like that on a knob with no principled value is not a
    /// finding count, and exposing the depth as configuration would let a project tune
    /// its way to zero.
    ///
    /// - Parameters:
    ///   - candidates: Shape-bearing functions from the source pass.
    ///   - calls: Caller-to-callee names, used for the one delegation level.
    ///   - coveredDirectly: Symbols named inside property-shaped tests.
    /// - Returns: Diagnostics ordered by file then line.
    public static func findings(
        candidates: [Candidate], calls: [String: Set<String>],
        coveredDirectly: Set<String>
    ) -> [Diagnostic] {
        var covered = coveredDirectly
        for name in coveredDirectly {
            covered.formUnion(calls[name] ?? [])
        }
        return candidates
            .filter { !covered.contains($0.name) }
            .sorted { ($0.path, $0.line) < ($1.path, $1.line) }
            .map { candidate in
                Diagnostic(
                    severity: .warning,
                    message: """
                        `\(candidate.name)` is \(article(for: candidate.shape)) \
                        \(candidate.shape.rawValue) and no property-shaped test exercises it. \
                        Assert that \(candidate.shape.invariant).
                        """,
                    filePath: candidate.path,
                    lineNumber: candidate.line,
                    ruleId: ruleId,
                    suggestedFix: """
                        Write one test that drives a seeded generator, loops a bounded range, \
                        or uses `@Test(arguments:)`. If the only invariant available restates \
                        the function body, it is a tautology — say so and exempt this line \
                        rather than writing it.
                        """)
            }
    }

    static func article(for shape: FunctionShape) -> String {
        "aeiou".contains(shape.rawValue.lowercased().prefix(1)) ? "an" : "a"
    }

    // MARK: - Text helpers

    /// Removes `"""` fixtures. A linter's tests embed source containing `@Test`, and
    /// counting those inflated this package's own test count from 2,968 to 3,068.
    static func strippingMultilineStrings(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while let open = text.range(of: "\"\"\"", range: index..<text.endIndex) {
            result += text[index..<open.lowerBound]
            guard let close = text.range(
                of: "\"\"\"", range: open.upperBound..<text.endIndex) else { return result }
            index = close.upperBound
        }
        result += text[index...]
        return result
    }

    /// The brace-matched body following an index.
    static func bracedBody(of text: String, from start: String.Index) -> String? {
        guard let open = text[start...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            else if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[text.index(after: open)..<index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Identifiers called as functions in a body.
    static func calledNames(in body: String) -> Set<String> {
        var names: Set<String> = []
        var searchStart = body.startIndex
        while let paren = body.range(of: "(", range: searchStart..<body.endIndex) {
            var nameEnd = paren.lowerBound
            var name = ""
            while nameEnd > body.startIndex {
                let previous = body.index(before: nameEnd)
                let character = body[previous]
                guard character.isLetter || character.isNumber || character == "_" else { break }
                name.insert(character, at: name.startIndex)
                nameEnd = previous
            }
            if !name.isEmpty { names.insert(name) }
            searchStart = paren.upperBound
        }
        return names
    }
}

/// Collects every function declaration with what the rule needs to classify it.
final class FunctionSurvey: SyntaxVisitor {

    struct Function {
        let name: String
        let takesText: Bool
        let line: Int
        let isNested: Bool
    }

    private(set) var functions: [Function] = []
    private(set) var calls: [String: Set<String>] = [:]
    private let converter: SourceLocationConverter
    private var functionDepth = 0

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let parameters = node.signature.parameterClause.parameters
        let takesText = parameters.contains { parameter in
            let type = parameter.type.trimmedDescription
            return ["String", "Substring", "Data", "[String]"].contains {
                type == $0 || type == "\($0)?"
            }
        }
        functions.append(Function(
            name: name, takesText: takesText,
            line: converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
            isNested: functionDepth > 0))

        if let body = node.body {
            var called: Set<String> = []
            for call in body.tokens(viewMode: .sourceAccurate) where call.tokenKind == .leftParen {
                if let previous = call.previousToken(viewMode: .sourceAccurate),
                   case .identifier(let text) = previous.tokenKind, text != name {
                    called.insert(text)
                }
            }
            calls[name, default: []].formUnion(called)
        }
        functionDepth += 1
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        functionDepth -= 1
    }
}
