import Foundation

/// How a single control is covered by the gate — the honest three-plus-one
/// states the compliance report is built on.
public enum ControlCoverageState: String, Sendable, Codable {
    /// A statically-checkable control with at least one real rule enforcing it.
    case enforced
    /// The gate's own operation is the evidence (e.g. change management) — no
    /// specific rule, but running the gate is the control.
    case evidenceOnly = "evidence-only"
    /// Out of reach for static analysis; requires process/documentation evidence.
    /// Listed explicitly, never hidden.
    case outOfScope = "out-of-scope"
    /// Statically checkable but not yet mapped to any rule — an honest coverage
    /// gap, surfaced rather than silently omitted.
    case gap
}

/// One control's coverage row in the compliance matrix.
public struct ControlCoverage: Sendable, Codable, Equatable {
    /// The framework the control belongs to.
    public let framework: String
    /// The control's framework-native id.
    public let controlId: String
    /// The control's title.
    public let title: String
    /// How the gate covers it.
    public let state: ControlCoverageState
    /// The rule IDs enforcing it (non-empty only for `.enforced`/`.evidenceOnly`).
    public let rules: [String]

    /// Creates a coverage row.
    public init(framework: String, controlId: String, title: String, state: ControlCoverageState, rules: [String]) {
        self.framework = framework
        self.controlId = controlId
        self.title = title
        self.state = state
        self.rules = rules
    }
}

/// Computes the control-coverage matrix from the mapping data — the honest
/// evidence artifact. It reports what static analysis *does* and *does not*
/// cover; it never asserts "compliant."
public enum ComplianceCoverage {

    /// One coverage row per control across all catalogs, classified by whether a
    /// real rule enforces it, the gate's operation evidences it, it's out of
    /// scope, or it's an unmapped gap.
    ///
    /// Only mappings whose rule is in `knownRuleIds` count — a phantom-rule
    /// mapping never manufactures coverage.
    public static func matrix(
        catalogs: [ControlCatalog],
        mappings: [RuleControlMapping],
        knownRuleIds: Set<String>
    ) -> [ControlCoverage] {
        var rows: [ControlCoverage] = []
        for catalog in catalogs {
            for control in catalog.controls {
                let rules = realRules(
                    for: control.id, framework: catalog.framework,
                    mappings: mappings, knownRuleIds: knownRuleIds)

                let state: ControlCoverageState
                switch control.checkability {
                case .none:
                    state = .outOfScope
                case .evidence:
                    state = .evidenceOnly
                case .partial:
                    state = rules.isEmpty ? .gap : .enforced
                }

                rows.append(ControlCoverage(
                    framework: catalog.framework,
                    controlId: control.id,
                    title: control.title,
                    state: state,
                    rules: state == .outOfScope ? [] : rules))
            }
        }
        return rows
    }

    /// The distinct, registry-known rule IDs that map to a given control,
    /// sorted for deterministic output.
    private static func realRules(
        for controlId: String,
        framework: String,
        mappings: [RuleControlMapping],
        knownRuleIds: Set<String>
    ) -> [String] {
        let matched = mappings
            .filter { knownRuleIds.contains($0.ruleId) }
            .filter { $0.satisfies.contains { $0.framework == framework && $0.controlId == controlId } }
            .map(\.ruleId)
        return Array(Set(matched)).sorted()
    }
}
