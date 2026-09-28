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

    /// A result with nothing in it.
    public static let empty = FallbackAuditResult(diagnostics: [], overrides: [], conversionsExamined: 0)
}

// MARK: - Entry point

/// The single implementation of the `fallback` rules.
///
/// `fp-safety` asks whether a divisor is guarded. These rules ask what happens
/// to a value that is *not a number at all*: a conversion that traps on it, and
/// (in later rules) a guard that answers for it.
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
            overrides: [],
            conversionsExamined: visitor.conversionsExamined
        )
    }

    /// True for a file under a `Tests/` directory.
    static func isTestFile(_ path: String) -> Bool {
        path.contains("/Tests/") || path.hasPrefix("Tests/")
    }
}
