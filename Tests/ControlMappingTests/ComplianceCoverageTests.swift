import Foundation
import Testing
@testable import ControlMapping

/// RegulatoryControlMapping Phase 1 — the compliance-coverage matrix.
///
/// Contract: each control is classified honestly — a checkable control with a
/// real mapped rule is `enforced`; an `evidence`-checkability control is
/// `evidence-only`; a `none`-checkability control is `out-of-scope` (never
/// hidden); a checkable control with no mapping is a `gap` (surfaced, not
/// omitted). A mapping to a rule not in the registry never counts as coverage.
@Suite("ComplianceCoverage")
struct ComplianceCoverageTests {

    private func control(_ id: String, _ checkability: Checkability) -> Control {
        Control(id: id, title: "Control \(id)", text: "…", checkability: checkability)
    }

    private func catalog(_ controls: [Control]) -> ControlCatalog {
        ControlCatalog(
            framework: "fw", version: "v", source: "s", sourceRef: "r",
            fetched: "2026-07-31", contentHash: "h", reviewedBy: "me",
            reviewed: "2026-07-31", superseded: false, controls: controls)
    }

    private func matrix(
        _ controls: [Control],
        mappings: [RuleControlMapping],
        known: Set<String>
    ) -> [ControlCoverage] {
        ComplianceCoverage.matrix(
            catalogs: [catalog(controls)], mappings: mappings, knownRuleIds: known)
    }

    private func map(_ rule: String, to controlId: String, posture: Checkability = .partial) -> RuleControlMapping {
        RuleControlMapping(
            ruleId: rule,
            satisfies: [ControlRef(framework: "fw", controlId: controlId)],
            posture: posture)
    }

    @Test("a checkable control with a real mapped rule is enforced, listing the rule")
    func enforced() throws {
        let rows = matrix(
            [control("A", .partial)],
            mappings: [map("real-rule", to: "A")],
            known: ["real-rule"])
        let row = try #require(rows.first { $0.controlId == "A" })
        #expect(row.state == .enforced)
        #expect(row.rules == ["real-rule"])
    }

    @Test("an out-of-scope control is reported, never hidden")
    func outOfScope() throws {
        let rows = matrix([control("B", Checkability.none)], mappings: [], known: [])
        let row = try #require(rows.first { $0.controlId == "B" })
        #expect(row.state == .outOfScope)
        #expect(row.rules.isEmpty)
    }

    @Test("an evidence-checkability control is evidence-only")
    func evidenceOnly() throws {
        let rows = matrix(
            [control("C", .evidence)],
            mappings: [map("gate-op", to: "C", posture: .evidence)],
            known: ["gate-op"])
        let row = try #require(rows.first { $0.controlId == "C" })
        #expect(row.state == .evidenceOnly)
    }

    @Test("a checkable control with no mapping is an honest gap")
    func gap() throws {
        let rows = matrix([control("D", .partial)], mappings: [], known: [])
        let row = try #require(rows.first { $0.controlId == "D" })
        #expect(row.state == .gap)
    }

    @Test("a mapping to an unknown rule does not count as enforcement")
    func phantomRuleIsNotCoverage() throws {
        let rows = matrix(
            [control("E", .partial)],
            mappings: [map("does-not-exist", to: "E")],
            known: ["real-rule"])
        let row = try #require(rows.first { $0.controlId == "E" })
        #expect(row.state == .gap)          // the phantom rule provides no real coverage
        #expect(row.rules.isEmpty)
    }

    @Test("the shipped HIPAA §164.312 slice: 2 enforced, 2 out-of-scope")
    func shippedHipaaMatrix() {
        let rows = ComplianceCoverage.matrix(
            catalogs: ControlMappingResources.catalogs(),
            mappings: ControlMappingResources.mappings(),
            knownRuleIds: ControlMappingResources.registryRuleIds())
        let hipaa = rows.filter { $0.framework == "hipaa-security-rule" }
        #expect(hipaa.filter { $0.state == .enforced }.count == 2)
        #expect(hipaa.filter { $0.state == .outOfScope }.count == 2)
        // transmission security is enforced by the transport rules
        let transmission = hipaa.first { $0.controlId == "164.312(e)(1)" }
        #expect(transmission?.state == .enforced)
        #expect(transmission?.rules.contains("security.insecure-transport") == true)
    }
}
