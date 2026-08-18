import Foundation
import Testing
@testable import QualityGateCore

/// `TrapPolicy`'s verdicts, pinned across the full cross product.
///
/// This is a **characterisation** test, not a red test. It is written to pass against the
/// implementation as it stands, so that extracting the ladder into `GraduatedPolicy` has
/// something to be invisible against. A refactor with no such test is a rewrite wearing a
/// refactor's name.
///
/// The expectations below are derived from the *specification* — escalation, then strict
/// context, then level — and written out longhand rather than computed by calling the code
/// under test, which would assert only that the function equals itself.
@Suite("TrapPolicy — verdicts are invariant under the protocol extraction")
struct GraduatedPolicyInvisibilityTests {

    private static let levels: [TrapPolicy] = [.forbidden, .justified, .aggregate]
    private static let targets: [TargetType] = [.executable, .library, .test, .plugin]

    /// Messages that must escalate, whatever the level or target.
    private static let unfinished = [
        "unimplemented", "TODO: finish this", "not implemented yet",
        "FIXME: broken", "unreachable", "UNIMPLEMENTED", "Todo",
    ]

    /// Messages that carry no escalation.
    private static let ordinary: [String?] = [
        nil, "index out of range", "invalid state", "the caller guarantees non-nil",
    ]

    /// Layer 3 alone: the level decides, once escalation and strict context are ruled out.
    private func levelVerdict(_ policy: TrapPolicy) -> TrapPolicy.Verdict {
        switch policy {
        case .forbidden: return .report
        case .justified: return .requireJustification
        case .aggregate: return .count
        }
    }

    @Test("An executable always reports, at every level and for every message")
    func executableIsAlwaysStrict() {
        for policy in Self.levels {
            for message in Self.ordinary + Self.unfinished.map({ Optional($0) }) {
                #expect(policy.verdict(targetType: .executable, message: message) == .report,
                        "level \(policy) message \(message ?? "nil")")
            }
        }
    }

    @Test("Unfinished work escalates past both the level and the target")
    func unfinishedWorkEscalates() {
        for policy in Self.levels {
            for target in Self.targets {
                for message in Self.unfinished {
                    #expect(policy.verdict(targetType: target, message: message) == .report,
                            "level \(policy) target \(target) message \(message)")
                }
            }
        }
    }

    @Test("Outside an executable, an ordinary trap gets the level's verdict")
    func nonExecutableFollowsLevel() {
        for policy in Self.levels {
            for target in [TargetType.library, .test, .plugin] {
                for message in Self.ordinary {
                    #expect(policy.verdict(targetType: target, message: message) == levelVerdict(policy),
                            "level \(policy) target \(target) message \(message ?? "nil")")
                }
            }
        }
    }

    /// The ordering is load-bearing and this is the test that says so.
    ///
    /// Put the level before the escalation and an `unimplemented` trap in a library under
    /// `aggregate` is silently counted instead of reported — a relaxation nobody asked for,
    /// invisible in every other assertion here.
    @Test("Escalation outranks the level: unimplemented in a library under aggregate reports")
    func escalationOutranksLevel() {
        #expect(TrapPolicy.aggregate.verdict(targetType: .library, message: "unimplemented") == .report)
        #expect(TrapPolicy.aggregate.verdict(targetType: .test, message: "TODO: later") == .report)
        #expect(TrapPolicy.aggregate.verdict(targetType: .plugin, message: "fixme") == .report)
    }

    /// The whole cross product, counted, so a case added later cannot slip past unexercised.
    @Test("The cross product is fully covered")
    func crossProductIsExhaustive() {
        #expect(TrapPolicy.allCases.count == Self.levels.count,
                "a new TrapPolicy case exists that this suite does not exercise")
        #expect(TargetType.allCases.count == Self.targets.count,
                "a new TargetType case exists that this suite does not exercise")
    }
}
