import Foundation

/// What became of one unit of documentation a checker set out to examine.
///
/// ## Why a third case exists
///
/// Two cases — it worked, or it produced diagnostics — cannot express *"I never
/// reached this."* Anything unreachable is then absorbed into the pass count, and
/// the run prints exactly what a fully-examined corpus prints.
///
/// This suite has shipped that failure three times, months apart, in checkers with
/// no shared code path:
///
/// - `doc-lint` handed DocC the first target of the first library product. It
///   examined **1 of 116 targets** and printed a clean result. Widening it surfaced
///   19 real defects that had been sitting there.
/// - `doc-code` matched fences at column zero, silently skipping every block nested
///   inside a list item. Six articles passed with API drift inside them.
/// - `ArticleDiscovery` looked only under `Sources/`. A package laid out with
///   `Source/` would have found zero catalogues and passed.
///
/// What those share is not a function. It is an output vocabulary in which the
/// failure could not be said. Making it sayable is the only fix that acts on the
/// class rather than on the three instances.
public enum AnalysisOutcome: Sendable, Equatable {

    /// The unit was examined and nothing was wrong with it.
    case analyzed

    /// The unit was examined and these are its defects.
    case failed([Diagnostic])

    /// The unit was **not** examined, and this is why.
    ///
    /// The reason is required rather than optional, and it must name the obstacle:
    /// *"target `BusinessMathMacros` is not built on this platform"* is actionable,
    /// *"could not analyze"* is the silence this case exists to break.
    ///
    /// This is a statement of fact by the checker. It is never an author-supplied
    /// escape — `<!-- docs:illustrative -->` is a human edit and stays one, and the
    /// two must not converge. A sweep that marks a corpus illustrative to clear a
    /// run is the failure this whole design guards against.
    case notAnalyzed(reason: String)

    /// Whether this unit was actually examined, whatever the verdict.
    public var wasExamined: Bool {
        switch self {
        case .analyzed, .failed: return true
        case .notAnalyzed: return false
        }
    }

    /// Diagnostics this outcome carries, if any.
    public var diagnostics: [Diagnostic] {
        switch self {
        case .failed(let diagnostics): return diagnostics
        case .analyzed, .notAnalyzed: return []
        }
    }

    /// Why the unit went unexamined, when it did.
    public var unanalyzedReason: String? {
        switch self {
        case .notAnalyzed(let reason): return reason
        case .analyzed, .failed: return nil
        }
    }
}

/// What a single run actually looked at, printed whether or not it found anything.
///
/// `doc-generated` has emitted this since the day it was written and is the one
/// member of this family never to have had the failure above, because the failure is
/// unsayable in its output. This type is that discipline made shared.
public struct AnalysisCoverage: Sendable, Equatable {

    /// What is being counted — `"fence"`, `"article"`, `"target"`. Singular; the
    /// summary pluralises.
    public let unit: String

    /// Units discovered.
    public let found: Int

    /// Units actually examined.
    public let examined: Int

    /// Units the author marked exempt, which is a decision rather than a gap.
    public let exempt: Int

    /// Units the checker could not examine, keyed by the reason it could not.
    ///
    /// Grouped rather than totalled because the reasons are what a reader acts on.
    /// Fourteen fences unanalyzable for one reason is a fix; fourteen for fourteen
    /// reasons is an investigation.
    public let unanalyzed: [String: Int]

    /// Creates a coverage record.
    public init(
        unit: String, found: Int, examined: Int, exempt: Int = 0,
        unanalyzed: [String: Int] = [:]
    ) {
        self.unit = unit
        self.found = found
        self.examined = examined
        self.exempt = exempt
        self.unanalyzed = unanalyzed
    }

    /// Total units left unexamined.
    public var notAnalyzedCount: Int { unanalyzed.values.reduce(0, +) }

    /// The one-line coverage statement, emitted on every run including a clean one.
    ///
    /// Reasons are sorted so two runs over an unchanged tree produce identical text.
    public var summary: String {
        var line = "\(unit)s: \(found) found · \(examined) examined"
        if exempt > 0 { line += " · \(exempt) exempt" }
        if notAnalyzedCount > 0 {
            let reasons = unanalyzed.keys.sorted()
                .map { "\($0) (\(unanalyzed[$0] ?? 0))" }
                .joined(separator: ", ")
            line += " · \(notAnalyzedCount) not analyzed: \(reasons)"
        } else {
            line += " · 0 not analyzed"
        }
        return line
    }

    /// The diagnostic to emit for this coverage.
    ///
    /// Finding nothing to examine is an **error**, not a pass. It is a statement
    /// about the checker's reach rather than about the project, and reporting it as
    /// a pass is precisely the defect this type exists to prevent.
    ///
    /// Whether *unanalyzed* units should also fail under `--strict` is deliberately
    /// left open: a target excluded on the current platform is correctly
    /// unanalyzable, and failing on correct code is how a gate gets switched off.
    ///
    /// - Parameters:
    ///   - checkerId: The checker's id, used to namespace the rule.
    ///   - corpusHint: What to suggest when nothing was found.
    /// - Returns: A note, or an error when nothing was discovered.
    public func diagnostic(checkerId: String, corpusHint: String? = nil) -> Diagnostic {
        guard found > 0 else {
            return Diagnostic(
                severity: .error,
                message: "\(checkerId) found no \(unit)s, so it examined nothing. "
                    + "A pass here would mean only that there was nothing to look at.",
                ruleId: "\(checkerId).no-coverage",
                suggestedFix: corpusHint)
        }
        return Diagnostic(
            severity: .note,
            message: summary,
            ruleId: "\(checkerId).coverage")
    }
}

extension Array where Element == AnalysisOutcome {

    /// Reduces outcomes to a coverage record.
    ///
    /// Coverage is *derived from* the outcomes rather than tallied beside them. A
    /// count maintained in parallel with the work eventually disagrees with the work,
    /// and then the number that is supposed to describe the run describes something
    /// else.
    ///
    /// - Parameters:
    ///   - unit: Singular noun for what was counted.
    ///   - found: Units discovered, which may exceed the outcomes when some were
    ///     never attempted.
    ///   - exempt: Units the author marked exempt.
    /// - Returns: The coverage these outcomes imply.
    public func coverage(unit: String, found: Int? = nil, exempt: Int = 0) -> AnalysisCoverage {
        var unanalyzed: [String: Int] = [:]
        var examined = 0
        for outcome in self {
            if let reason = outcome.unanalyzedReason {
                unanalyzed[reason, default: 0] += 1
            } else {
                examined += 1
            }
        }
        return AnalysisCoverage(
            unit: unit, found: found ?? count, examined: examined,
            exempt: exempt, unanalyzed: unanalyzed)
    }
}
