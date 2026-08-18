import Foundation

/// The three strengths a rule family can be held at.
///
/// Separated from any particular family so a second one costs a conformance rather than a copy.
/// The names are `TrapPolicy`'s, because that family established them and its meanings carried.
public enum PolicyLevel: String, Sendable, Codable, CaseIterable, Equatable {

    /// Report every site. The strictest reading, and the right one for code you own.
    case forbidden

    /// Report a site unless it carries a stated reason.
    case justified

    /// Count sites into one note instead of reporting them.
    ///
    /// The honest setting for code the operator cannot change. A survey of thirty repositories
    /// cannot demand annotations, and a rule that reports thousands of findings against code
    /// nobody here wrote is a rule that gets switched off — which reports nothing at all.
    case aggregate
}

/// What to do about one site.
public enum PolicyVerdict: Sendable, Equatable {
    /// A finding.
    case report
    /// Not a finding; counted into the run's aggregate note.
    case count
    /// A finding unless the site carries a stated justification.
    case requireJustification
}

/// A rule family that can be held at three strengths, relaxed by context, and escalated past
/// both by evidence.
///
/// ## Why this is a protocol and not three copies
///
/// `TrapPolicy` decides whether a `fatalError` is a defect, and the same question — *is this a
/// defect here, or merely a fact about code somebody else owns?* — arises for forced
/// operations, and will arise again. Copying the decision is how two policies drift into
/// answering it differently, and the drift is silent because each copy looks correct alone.
///
/// ## The order is the whole point
///
/// ``verdict(in:evidence:)`` applies three layers in a fixed sequence: escalation, then strict
/// context, then level. **Reordering them is a silent relaxation** — put the level first and an
/// `unimplemented` trap in a library under ``PolicyLevel/aggregate`` is counted rather than
/// reported, which no test that checks one layer at a time would catch. So the sequence lives
/// here, once, and conformers supply only the predicates it consults.
///
/// ## Conforming
///
/// A new family supplies a ``level``, an ``alwaysReports(in:)`` predicate and an
/// ``aggregateNoun``. ``escalates(_:)`` defaults to `false`, so a family with no escalation
/// says nothing about it; one that grows an escalation later overrides a single method.
public protocol GraduatedPolicy: Sendable, Equatable {

    /// What the finding sits in — the target type, ordinarily.
    associatedtype Context

    /// Whatever the escalation reads.
    ///
    /// Defaulted to `Void`, and the default is load-bearing rather than tidy: Swift cannot
    /// infer an associated type from a *defaulted* extension method, so without it a family
    /// with no escalation has to write `typealias Evidence = Void` by hand. That would make the
    /// cost of conforming four members rather than three — which a test caught by failing to
    /// compile against the version of this protocol that omitted it.
    associatedtype Evidence = Void

    /// The strength this family is being held at.
    var level: PolicyLevel { get }

    /// Contexts where the relaxation never applies — where an end user is downstream.
    ///
    /// - Parameter context: The context the site sits in.
    /// - Returns: `true` when the site must be reported whatever the level says.
    func alwaysReports(in context: Context) -> Bool

    /// Evidence that outranks both the level and the context.
    ///
    /// - Parameter evidence: The family's evidence for this site.
    /// - Returns: `true` when the site must be reported regardless.
    func escalates(_ evidence: Evidence) -> Bool

    /// The noun the aggregate note counts: `"trap"`, `"forced operation"`.
    var aggregateNoun: String { get }
}

extension GraduatedPolicy {

    /// The verdict for one site: escalation, then strict context, then level.
    ///
    /// - Parameters:
    ///   - context: Where the site sits.
    ///   - evidence: What the family knows about this site.
    /// - Returns: Whether to report, require a justification, or count it.
    public func verdict(in context: Context, evidence: Evidence) -> PolicyVerdict {
        // Escalation outranks everything, including the context relaxation.
        if escalates(evidence) { return .report }
        // Then the contexts that never relax.
        if alwaysReports(in: context) { return .report }
        // Only then does the level get a say.
        switch level {
        case .forbidden: return .report
        case .justified: return .requireJustification
        case .aggregate: return .count
        }
    }

    /// Most families have no escalation; opting in means overriding this one method.
    public func escalates(_ evidence: Evidence) -> Bool { false }
}
