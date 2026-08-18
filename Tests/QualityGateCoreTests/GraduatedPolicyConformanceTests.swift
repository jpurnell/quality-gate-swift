import Foundation
import Testing
@testable import QualityGateCore

/// What a second family costs.
///
/// The claim in `ForcedOperationPolicy.md` is that conforming costs "a level, a context
/// predicate and a noun". That is a claim about the shape, and a claim about a shape is
/// checkable by writing the smallest possible conformer and seeing whether it compiles.
/// If this file ever needs more than the three members below, the abstraction has grown a
/// requirement its own proposal did not intend.
@Suite("GraduatedPolicy — the cost of a second conformer")
struct GraduatedPolicyConformanceTests {

    /// The minimum: a level, a context predicate, a noun. No escalation.
    private struct MinimalPolicy: GraduatedPolicy {
        let level: PolicyLevel
        func alwaysReports(in context: TargetType) -> Bool { context == .executable }
        var aggregateNoun: String { "widget" }
    }

    /// A family that grows an escalation later overrides exactly one method.
    private struct EscalatingPolicy: GraduatedPolicy {
        let level: PolicyLevel
        func alwaysReports(in context: TargetType) -> Bool { context == .executable }
        func escalates(_ evidence: Bool) -> Bool { evidence }
        var aggregateNoun: String { "widget" }
    }

    @Test("A conformer with no escalation compiles and takes the default")
    func minimalConformerUsesDefaultEscalation() {
        let policy = MinimalPolicy(level: .aggregate)
        // `Evidence` is inferred from the defaulted `escalates`; passing `()` exercises it.
        #expect(policy.verdict(in: .library, evidence: ()) == .count)
        #expect(policy.verdict(in: .executable, evidence: ()) == .report)
    }

    @Test("The ladder applies identically to a family that is not TrapPolicy")
    func ladderIsFamilyAgnostic() {
        #expect(MinimalPolicy(level: .forbidden).verdict(in: .test, evidence: ()) == .report)
        #expect(MinimalPolicy(level: .justified).verdict(in: .test, evidence: ()) == .requireJustification)
        #expect(MinimalPolicy(level: .aggregate).verdict(in: .test, evidence: ()) == .count)
    }

    /// The ordering guarantee is a property of the protocol, not of `TrapPolicy`.
    @Test("An overridden escalation outranks both the level and the context")
    func escalationOutranksForAnyConformer() {
        let lenient = EscalatingPolicy(level: .aggregate)
        #expect(lenient.verdict(in: .library, evidence: true) == .report,
                "escalation must outrank aggregate")
        #expect(lenient.verdict(in: .library, evidence: false) == .count,
                "without escalation the level decides")
    }
}
