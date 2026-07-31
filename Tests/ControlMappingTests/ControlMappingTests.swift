import Foundation
import Testing
import QualityGateCore
@testable import ControlMapping

/// RegulatoryControlMapping Phase 0 — the mapping machinery.
///
/// Two contracts: the data model round-trips (catalog freshness metadata,
/// string-form control refs), and the validator flags structural drift
/// (phantom rule, phantom control) as errors while catalog staleness ages from
/// a warning and an upstream-superseded catalog is an error.
@Suite("ControlMapping")
struct ControlMappingTests {

    // MARK: - Fixtures

    private func hipaaCatalog(reviewed: String = "2026-07-01", superseded: Bool = false) -> ControlCatalog {
        ControlCatalog(
            framework: "hipaa-security-rule",
            version: "45 CFR 164 · 2013 Final Rule",
            source: "ecfr",
            sourceRef: "https://www.ecfr.gov/current/title-45/part-164",
            fetched: "2026-07-01",
            contentHash: "sha256:abc",
            reviewedBy: "jpurnell",
            reviewed: reviewed,
            superseded: superseded,
            controls: [
                Control(
                    id: "164.312(e)(1)",
                    title: "Transmission security",
                    text: "Implement technical security measures to guard against unauthorized access to ePHI transmitted over a network.",
                    checkability: .partial),
            ])
    }

    private func mapping(rule: String = "security.insecure-transport", ref: String = "hipaa-security-rule/164.312(e)(1)") -> RuleControlMapping {
        RuleControlMapping(
            ruleId: rule,
            satisfies: [ControlRef(ref) ?? ControlRef(framework: "x", controlId: "y")],
            posture: .partial)
    }

    private func validate(
        _ mappings: [RuleControlMapping],
        catalogs: [ControlCatalog],
        knownRuleIds: Set<String>,
        horizon: Int = 180,
        today: String = "2026-07-30"
    ) -> [Diagnostic] {
        ControlMappingValidator.validate(
            mappings: mappings, catalogs: catalogs,
            knownRuleIds: knownRuleIds, freshnessHorizonDays: horizon, today: today)
    }

    // MARK: - Data model

    @Test("a control ref round-trips through its framework/controlId string form")
    func controlRefStringForm() throws {
        let ref = try #require(ControlRef("hipaa-security-rule/164.312(e)(1)"))
        #expect(ref.framework == "hipaa-security-rule")
        #expect(ref.controlId == "164.312(e)(1)")
        #expect(ref.stringValue == "hipaa-security-rule/164.312(e)(1)")
    }

    @Test("a control ref without a slash is rejected")
    func controlRefRejectsMalformed() {
        #expect(ControlRef("no-slash-here") == nil)
    }

    @Test("a catalog round-trips through Codable, defaulting superseded to false")
    func catalogCodableRoundTrip() throws {
        let catalog = hipaaCatalog()
        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(ControlCatalog.self, from: data)
        #expect(decoded == catalog)
        #expect(decoded.control(id: "164.312(e)(1)")?.title == "Transmission security")
        #expect(decoded.control(id: "nonexistent") == nil)
    }

    // MARK: - Validator: clean

    @Test("a well-formed, fresh mapping produces no findings")
    func cleanMapping() {
        let findings = validate(
            [mapping()],
            catalogs: [hipaaCatalog()],
            knownRuleIds: ["security.insecure-transport"])
        #expect(findings.isEmpty)
    }

    // MARK: - Validator: structural drift (errors)

    @Test("a mapping to an unknown rule is an error")
    func phantomRule() throws {
        let findings = validate(
            [mapping(rule: "does-not-exist")],
            catalogs: [hipaaCatalog()],
            knownRuleIds: ["security.insecure-transport"])
        #expect(findings.contains { $0.severity == .error && ($0.ruleId ?? "").contains("unknown-rule") })
    }

    @Test("a mapping to an unknown control is an error")
    func phantomControl() {
        let findings = validate(
            [mapping(ref: "hipaa-security-rule/164.999(z)")],
            catalogs: [hipaaCatalog()],
            knownRuleIds: ["security.insecure-transport"])
        #expect(findings.contains { $0.severity == .error && ($0.ruleId ?? "").contains("unknown-control") })
    }

    @Test("a mapping to an unknown framework is an error")
    func phantomFramework() {
        let findings = validate(
            [mapping(ref: "no-such-framework/1.2.3")],
            catalogs: [hipaaCatalog()],
            knownRuleIds: ["security.insecure-transport"])
        #expect(findings.contains { $0.severity == .error && ($0.ruleId ?? "").contains("unknown-control") })
    }

    // MARK: - Validator: freshness (ages from a warning)

    @Test("a catalog reviewed within the horizon does not warn")
    func freshCatalog() {
        let findings = validate(
            [mapping()],
            catalogs: [hipaaCatalog(reviewed: "2026-07-01")],
            knownRuleIds: ["security.insecure-transport"],
            horizon: 180, today: "2026-07-30")
        #expect(!findings.contains { ($0.ruleId ?? "").contains("stale") })
    }

    @Test("a catalog past the freshness horizon warns")
    func staleCatalog() {
        let findings = validate(
            [mapping()],
            catalogs: [hipaaCatalog(reviewed: "2025-01-01")],
            knownRuleIds: ["security.insecure-transport"],
            horizon: 180, today: "2026-07-30")
        #expect(findings.contains { $0.severity == .warning && ($0.ruleId ?? "").contains("stale") })
    }

    @Test("an upstream-superseded catalog is an error, not just a warning")
    func supersededCatalog() {
        let findings = validate(
            [mapping()],
            catalogs: [hipaaCatalog(reviewed: "2026-07-01", superseded: true)],
            knownRuleIds: ["security.insecure-transport"],
            horizon: 180, today: "2026-07-30")
        #expect(findings.contains { $0.severity == .error && ($0.ruleId ?? "").contains("superseded") })
    }

    // MARK: - Bundled resources (the live data)

    @Test("the bundled rule registry loads and includes real rule IDs")
    func registryLoads() {
        let ids = ControlMappingResources.registryRuleIds()
        #expect(ids.contains("keychain-secrets"))
        #expect(ids.contains("privacy-manifest"))
        #expect(ids.contains("security.insecure-transport"))
        #expect(ids.count > 100)
    }

    @Test("the bundled HIPAA catalog loads with its §164.312 controls")
    func catalogLoads() throws {
        let catalogs = ControlMappingResources.catalogs()
        let hipaa = try #require(catalogs.first { $0.framework == "hipaa-security-rule" })
        #expect(hipaa.source == "ecfr")
        #expect(hipaa.control(id: "164.312(e)(1)")?.title == "Transmission security")
        #expect(hipaa.control(id: "164.312(a)(2)(iv)")?.checkability == .partial)
        #expect(hipaa.control(id: "164.312(b)")?.checkability == Checkability.none)
    }

    @Test("the bundled mapping loads and points at real rules")
    func mappingLoads() {
        let mappings = ControlMappingResources.mappings()
        #expect(mappings.count >= 6)
        #expect(mappings.contains { $0.ruleId == "keychain-secrets" })
        #expect(mappings.contains { $0.ruleId == "security.insecure-transport" })
    }

    @Test("the shipped mapping is internally consistent — no phantom rule or control")
    func shippedDataIsValid() {
        let findings = ControlMappingValidator.validate(
            mappings: ControlMappingResources.mappings(),
            catalogs: ControlMappingResources.catalogs(),
            knownRuleIds: ControlMappingResources.registryRuleIds(),
            freshnessHorizonDays: 180,
            today: "2026-07-31")
        #expect(!findings.contains { $0.severity == .error })
    }
}
