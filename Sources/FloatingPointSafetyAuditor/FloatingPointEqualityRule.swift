import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

// MARK: - Suppression markers

/// The suppression marker set for the floating-point rules.
///
/// One rule, one marker set. `fp-equality` and `exact-double-equality` are the
/// same detection reported by two checkers, so a marker that silences one must
/// silence the other — otherwise a developer reads a diagnostic, applies the
/// marker it names, re-runs, and still fails because the other checker owns the
/// rule in that directory.
///
/// `// fp-safety:disable` is canonical: it names the rule family rather than a
/// checker, and it is the marker already carried by the overwhelming majority of
/// sites in consumer projects. `// TEST-QUALITY:` is retained because removing it
/// would break every existing suppression in test code at once.
public enum FloatingPointSuppression {
    /// The marker to reach for. Named after the rule, not the checker.
    public static let canonicalMarker = "// fp-safety:disable"

    /// Markers retained for compatibility. Still honoured, by both checkers.
    public static let legacyMarkers = ["// TEST-QUALITY:"]

    /// Every marker either checker honours, before per-project additions.
    public static let allMarkers = [canonicalMarker] + legacyMarkers

    /// A line consisting of exactly the canonical marker and nothing else
    /// disables the floating-point rules for the whole file.
    static func disablesWholeFile(_ sourceLines: [String]) -> Bool {
        sourceLines.contains { $0.trimmingCharacters(in: .whitespaces) == canonicalMarker }
    }
}

// MARK: - Diagnostic text

/// The wording for the exact-comparison finding.
///
/// The rule cannot tell which of three claims an `==` is making, so it names all
/// three rather than asserting one. A confidently wrong suggested fix gets
/// followed: the previous text ("Use tolerance: abs(a - b) < epsilon") is wrong
/// advice for roughly half of real sites, and applying it weakens assertions that
/// were already correct.
///
/// The resolution offered is always a *named comparison*, never another marker.
/// A named call states the claim in the code and cannot drift from it; a marker
/// asserts intent and can be wrong forever.
public enum FloatingPointEqualityDiagnostic {

    /// The primary message for an exact comparison with `operatorText`.
    public static func message(operatorText: String) -> String {
        let form = forms(operatorText: operatorText)
        return """
        Exact '\(operatorText)' on floating-point operands. Three different claims hide under this \
        operator and the checker cannot tell which you mean, so state it. \
        Computed values, rounding expected: \(form.tolerance). \
        IEEE 754 comparison, chosen deliberately: \(form.ieee) — same result as '\(operatorText)', \
        but named, so it reads as a decision rather than an oversight. \
        Bit-identical results: \(form.bits) — '\(operatorText)' reports NaN as unequal to itself \
        and +0.0 as equal to -0.0, so a reproducibility check written with '\(operatorText)' can \
        pass with a NaN in the stream.
        """
    }

    /// The compact menu, shortest and most common first.
    public static func suggestedFix(operatorText: String) -> String {
        let form = forms(operatorText: operatorText)
        return "Rewrite as one of: \(form.tolerance) (computed, rounding expected) | "
            + "\(form.ieee) (IEEE 754, deliberate) | "
            + "\(form.bits) (bit-identical, distinguishes NaN and signed zero)"
    }

    private static func forms(operatorText: String) -> (tolerance: String, ieee: String, bits: String) {
        if operatorText == "!=" {
            return (
                tolerance: "abs(a - b) >= epsilon",
                ieee: "!a.isEqual(to: b)",
                bits: "a.bitPattern != b.bitPattern"
            )
        }
        return (
            tolerance: "abs(a - b) < epsilon",
            ieee: "a.isEqual(to: b)",
            bits: "a.bitPattern == b.bitPattern"
        )
    }
}

// MARK: - Rule options

/// How a checker wants the shared floating-point rules reported.
///
/// Everything here is *reporting* configuration. The detection itself is
/// identical for every caller — that is the point of the type.
public struct FloatingPointRuleOptions: Sendable {
    /// Rule identifier for the exact-comparison finding.
    public var equalityRuleId: String
    /// Severity for the exact-comparison finding.
    public var equalitySeverity: Diagnostic.Severity
    /// Whether to also run the unguarded-division rule.
    public var checkDivisionGuards: Bool
    /// Whether files under a `Tests/` path are skipped entirely.
    public var skipTestFiles: Bool
    /// Restrict exact-comparison findings to `#expect` / `#require` arguments.
    public var equalityRequiresAssertionContext: Bool
    /// Project-configured markers honoured in addition to ``FloatingPointSuppression/allMarkers``.
    public var extraSuppressionMarkers: [String]

    /// Creates reporting options for the shared floating-point rules.
    public init(
        equalityRuleId: String = "fp-equality",
        equalitySeverity: Diagnostic.Severity = .warning,
        checkDivisionGuards: Bool = true,
        skipTestFiles: Bool = true,
        equalityRequiresAssertionContext: Bool = false,
        extraSuppressionMarkers: [String] = []
    ) {
        self.equalityRuleId = equalityRuleId
        self.equalitySeverity = equalitySeverity
        self.checkDivisionGuards = checkDivisionGuards
        self.skipTestFiles = skipTestFiles
        self.equalityRequiresAssertionContext = equalityRequiresAssertionContext
        self.extraSuppressionMarkers = extraSuppressionMarkers
    }

    /// How `fp-safety` reports the rules over `Sources/`: warnings, everywhere
    /// in the file, division rule included.
    public static func sources(checkDivisionGuards: Bool) -> FloatingPointRuleOptions {
        FloatingPointRuleOptions(checkDivisionGuards: checkDivisionGuards)
    }

    /// How `test-quality` reports the rule over `Tests/`: an error, and only
    /// inside an assertion.
    ///
    /// The assertion-context restriction is deliberate and predates this
    /// unification — `exact-double-equality` is a rule about what a test
    /// *claims*, not about arithmetic in fixtures and helpers. Delegation
    /// preserves it.
    public static func testAssertions(extraSuppressionMarkers: [String]) -> FloatingPointRuleOptions {
        FloatingPointRuleOptions(
            equalityRuleId: "exact-double-equality",
            equalitySeverity: .error,
            checkDivisionGuards: false,
            skipTestFiles: false,
            equalityRequiresAssertionContext: true,
            extraSuppressionMarkers: extraSuppressionMarkers
        )
    }
}

// MARK: - Entry point

/// The single implementation of the floating-point rules.
///
/// Both `FloatingPointSafetyAuditor` and `TestQualityAuditor` come through here.
/// Two copies of a rule drift: they drifted on the suppression marker, on which
/// comparisons count, and on what the diagnostic advised.
public enum FloatingPointRules {

    /// Runs the floating-point rules over one source file.
    ///
    /// - Parameters:
    ///   - source: The Swift source text.
    ///   - fileName: Path used in emitted diagnostics.
    ///   - options: How the calling checker wants findings reported.
    ///   - parsedTree: An already-parsed tree for `source`, to avoid a second parse.
    /// - Returns: Active diagnostics, and override records for findings a
    ///   suppression marker silenced.
    public static func audit(
        source: String,
        fileName: String,
        options: FloatingPointRuleOptions,
        parsedTree: SourceFileSyntax? = nil
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let sourceLines = source.lines
        guard !FloatingPointSuppression.disablesWholeFile(sourceLines) else {
            return ([], [])
        }

        let tree = parsedTree ?? Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = FloatingPointSafetyVisitor(
            filePath: fileName,
            converter: converter,
            sourceLines: sourceLines,
            checkDivisionGuards: options.checkDivisionGuards,
            skipTestFiles: options.skipTestFiles,
            equalityRuleId: options.equalityRuleId,
            equalitySeverity: options.equalitySeverity,
            equalityRequiresAssertionContext: options.equalityRequiresAssertionContext,
            suppressionMarkers: FloatingPointSuppression.allMarkers + options.extraSuppressionMarkers
        )
        visitor.walk(tree)
        return (visitor.diagnostics, visitor.overrides)
    }
}
