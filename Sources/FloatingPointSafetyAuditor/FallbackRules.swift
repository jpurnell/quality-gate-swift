import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

// MARK: - Rule identifiers

/// The rule identifiers of the `fallback` family.
///
/// Named once so the checker, its tests and its documentation cannot disagree
/// on a spelling.
public enum FallbackRuleID {
    /// `Int(x)` on a floating-point `x` that nothing has shown to be representable.
    public static let intConversionUnguarded = "fallback.int-conversion-unguarded"

    /// `max(a, min(b, x))` on a floating-point `x`, which returns a bound for a NaN.
    public static let clampAbsorbsNaN = "fallback.clamp-absorbs-nan"

    /// An `if` / `else if` chain that sorts a floating-point value by comparison
    /// and never asks whether it is a number.
    public static let classificationOmitsNaN = "fallback.classification-omits-nan"

    /// A guard that a NaN fails, answering with a value nothing documents.
    /// Advisory: the checker cannot know whether the value is right.
    public static let guardReturnsAValue = "fallback.guard-returns-a-value"

    /// A `// fallback-justified:` marker with no reason after it.
    public static let justificationEmpty = "fallback.justification-empty"

    /// The note every run emits, pass or fail, saying what was examined.
    public static let coverage = "fallback.coverage"
}

// MARK: - Result

/// What the `fallback` rules found in one file.
public struct FallbackAuditResult: Sendable {
    /// Active diagnostics.
    public var diagnostics: [Diagnostic]

    /// Override records for findings a suppression marker silenced.
    public var overrides: [DiagnosticOverride]

    /// How many integer conversions of a floating-point value were examined,
    /// guarded or not. Reported so that a clean run over a file with none reads
    /// differently from a clean run over a file with forty.
    public var conversionsExamined: Int

    /// How many nested `min` / `max` clamps of a floating-point value were examined.
    public var clampsExamined: Int

    /// How many `if` / `else if` chains sorting one floating-point value were examined.
    public var classificationsExamined: Int

    /// How many guards that a NaN fails, and that answer with a value, were
    /// examined — documented, justified or neither.
    public var guardsExamined: Int

    /// A result with nothing in it.
    public static let empty = FallbackAuditResult(
        diagnostics: [],
        overrides: [],
        conversionsExamined: 0,
        clampsExamined: 0,
        classificationsExamined: 0,
        guardsExamined: 0
    )
}

// MARK: - Entry point

/// The single implementation of the `fallback` rules.
///
/// `fp-safety` asks whether a divisor is guarded. These rules ask what happens
/// to a value that is *not a number at all*: a conversion that traps on it, a
/// clamp that reports a bound for it, a chain of comparisons that sorts it into
/// whichever arm is last, and a guard that answers for it.
public enum FallbackRules {

    /// Runs the `fallback` rules over one source file.
    ///
    /// - Parameters:
    ///   - source: The Swift source text.
    ///   - fileName: Path used in emitted diagnostics.
    ///   - isTestFile: Whether the file is test code, which is not audited. Nil
    ///     decides from `fileName`; a caller that knows the repository-relative
    ///     path should decide from that and say so.
    ///   - parsedTree: An already-parsed tree for `source`, to avoid a second parse.
    /// - Returns: What was found, and how much was examined to find it.
    public static func audit(
        source: String,
        fileName: String,
        isTestFile: Bool? = nil,
        parsedTree: SourceFileSyntax? = nil
    ) -> FallbackAuditResult {
        // Production code only. A test that feeds a NaN to a conversion to see
        // it trap is doing its job.
        guard !(isTestFile ?? Self.isTestFile(fileName)) else { return .empty }

        let tree = parsedTree ?? Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)

        let visitor = FallbackVisitor(
            filePath: fileName,
            converter: converter,
            declarations: FallbackDeclarationCollector.collect(from: tree)
        )
        visitor.walk(tree)
        return FallbackAuditResult(
            diagnostics: visitor.diagnostics,
            overrides: visitor.overrides,
            conversionsExamined: visitor.conversionsExamined,
            clampsExamined: visitor.clampsExamined,
            classificationsExamined: visitor.classificationsExamined,
            guardsExamined: visitor.guardsExamined
        )
    }

    /// True for a file under a `Tests/` directory.
    static func isTestFile(_ path: String) -> Bool {
        path.contains("/Tests/") || path.hasPrefix("Tests/")
    }
}
