import Foundation

/// A function shape that carries an invariant regardless of what the function means.
///
/// The trigger is syntactic on purpose. `test_driven_development.md` §4 asked for
/// property-based tests "where mathematically applicable" from the day it was
/// written, and that phrasing made it skippable for anyone not writing numerics — the
/// rule existed and did not work. A shape is decidable from a signature; "applicable"
/// is not.
///
/// ## What each shape owes
///
/// | shape | invariant |
/// |---|---|
/// | parser | never traps on arbitrary input; every element of the output occurs in the input |
/// | comparator | `diff(a,b).isEmpty` iff `a == b`; symmetric; reflexive |
/// | ordering | total and stable; applying it twice changes nothing |
/// | balance | on balanced input the returned index closes the opener |
/// | normaliser | idempotent: `f(f(x)) == f(x)` |
/// | round-trip | `parse(render(x)) == x` |
///
/// ## What is deliberately not a shape
///
/// A renderer with no inverse. `emitDiagnostics` cannot round-trip, and demanding a
/// property of it demands a tautology — an assertion that restates the function body
/// and doubles the maintenance. Renderers qualify only when the **same file** also
/// parses, which is the usable proxy for "the two halves live in the same type".
///
/// Module scope was tried first and is too coarse: `QualityGateCore` contains parsers,
/// so `formatDuration`, `renderTable` and two `writeDiagnostic` overloads were
/// classified as round-trips while having no inverse anywhere.
public enum FunctionShape: String, Sendable, CaseIterable {

    /// Takes text, returns structure.
    case parser

    /// Decides whether two things agree.
    case comparator

    /// Imposes an order.
    case ordering

    /// Finds the delimiter that closes another.
    case balance

    /// Maps input onto a canonical form.
    case normaliser

    /// A renderer whose file also parses.
    case roundTrip

    /// The invariant a property for this shape should assert.
    ///
    /// Emitted in the diagnostic, because a finding that names the shape without
    /// naming the invariant tells an author they have work to do and not what it is.
    public var invariant: String {
        switch self {
        case .parser:
            return "it never traps on arbitrary input, and every element of its output occurs in its input"
        case .comparator:
            return "the comparison is empty exactly when the inputs are equal, and is symmetric"
        case .ordering:
            return "the order is total and stable, and applying it twice changes nothing"
        case .balance:
            return "on balanced input the returned index closes the opener it was given"
        case .normaliser:
            return "it is idempotent — applying it to its own output changes nothing"
        case .roundTrip:
            return "parsing what it renders returns the value it was given"
        }
    }

    // MARK: - Classification

    private static let parserVerbs = ["parse", "decode", "read", "extract", "scan",
                                      "tokenize", "tokenise", "split", "lex"]
    private static let renderVerbs = ["render", "encode", "format", "serialize",
                                      "serialise", "describe", "emit", "write"]
    private static let compareVerbs = ["compare", "diff", "match", "matches", "equal",
                                       "contains", "overlaps", "issubset"]
    private static let orderVerbs = ["sort", "order", "rank", "prioritize", "prioritise",
                                     "merge"]
    private static let normalVerbsWithText = ["normalize", "normalise", "canonical",
                                              "canonicalize", "canonicalise", "sanitize",
                                              "sanitise", "trim", "clean"]
    private static let balanceMarkers = ["matching", "balanced", "closing", "enclosing"]

    /// Classifies a function by name and signature.
    ///
    /// - Parameters:
    ///   - name: The function's base name.
    ///   - takesText: Whether any parameter is `String`, `Substring`, `Data` or `[String]`.
    ///   - fileAlsoParses: Whether the same file declares a parser-shaped function.
    /// - Returns: The shape, or `nil` when the function carries no invariant this rule
    ///   can name.
    public static func classify(
        name: String, takesText: Bool, fileAlsoParses: Bool
    ) -> FunctionShape? {
        let lowered = name.lowercased()
        func startsWithVerb(_ verbs: [String]) -> Bool {
            verbs.contains { lowered == $0 || lowered.hasPrefix($0) }
        }

        // Balance is checked before comparator: `matchingParen` contains "match" and is
        // a bracket matcher, not a predicate about equality.
        if balanceMarkers.contains(where: { lowered.contains($0) }) { return .balance }
        if startsWithVerb(parserVerbs), takesText { return .parser }
        if startsWithVerb(compareVerbs) { return .comparator }
        if startsWithVerb(orderVerbs) { return .ordering }
        if startsWithVerb(normalVerbsWithText), takesText { return .normaliser }
        if startsWithVerb(renderVerbs), fileAlsoParses { return .roundTrip }
        return nil
    }

    /// Whether a name looks like a parser, used to decide a file's pairing before any
    /// function in it is classified.
    static func looksLikeParser(name: String, takesText: Bool) -> Bool {
        guard takesText else { return false }
        let lowered = name.lowercased()
        return parserVerbs.contains { lowered == $0 || lowered.hasPrefix($0) }
    }
}
