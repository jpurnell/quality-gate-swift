import Foundation
import Testing
import SafetyAuditor
@testable import ControlMapping

/// CWE as a fourth catalogue.
///
/// The gate could not say which weaknesses it covers: CWE lived in one manifest of ten
/// `security.*` rules, and every other rule that is plainly about a named weakness was
/// untagged. Mapping rules to CWE through the machinery that already maps them to SOC 2,
/// ISO 27001 and HIPAA makes the answer a computed one — including the half that matters,
/// the weaknesses listed in the catalogue that no rule reaches.
@Suite("Weakness mapping (CWE)")
struct WeaknessMappingTests {

    private func cweCatalog() throws -> ControlCatalog {
        try #require(ControlMappingResources.catalogs().first { $0.framework == "cwe" })
    }

    private func cweMappings() -> [RuleControlMapping] {
        ControlMappingResources.mappings().filter { mapping in
            mapping.satisfies.contains { $0.framework == "cwe" }
        }
    }

    private func matrix() -> [ControlCoverage] {
        ComplianceCoverage.matrix(
            catalogs: ControlMappingResources.catalogs(),
            mappings: ControlMappingResources.mappings(),
            knownRuleIds: ControlMappingResources.registryRuleIds()
        ).filter { $0.framework == "cwe" }
    }

    // MARK: - The catalogue

    @Test("the bundled CWE catalogue loads, attributed to MITRE")
    func catalogLoads() throws {
        let catalog = try cweCatalog()
        #expect(catalog.source == "mitre")
        #expect(catalog.sourceRef.contains("cwe.mitre.org"))
        #expect(catalog.control(id: "CWE-476")?.title == "NULL Pointer Dereference")
    }

    /// An id that is not `CWE-<digits>` is a typo waiting to be cited in a report.
    @Test("every catalogue entry is identified as CWE-<number>, once")
    func idsAreWellFormed() throws {
        let ids = try cweCatalog().controls.map(\.id)
        #expect(Set(ids).count == ids.count, "a CWE is listed twice")
        for id in ids {
            let digits = id.dropFirst(4)
            #expect(id.hasPrefix("CWE-") && !digits.isEmpty && digits.allSatisfy(\.isNumber),
                    "'\(id)' is not of the form CWE-<number>")
        }
    }

    /// MITRE's own record of each catalogued id, committed so a test can hold the catalogue to
    /// it without the network: the title MITRE gives, and whether MITRE allows mapping to it.
    private struct Snapshot: Decodable {
        struct Entry: Decodable { let title: String; let usage: String? }
        let version: String
        let entries: [String: Entry]
    }

    private func snapshot() throws -> Snapshot {
        let url = try #require(Bundle.module.url(forResource: "cwe-4.20.snapshot", withExtension: "json"))
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }

    /// The catalogue was written from MITRE's data; this keeps it that way.
    @Test("every catalogue title is MITRE's title for that id")
    func titlesMatchMITRE() throws {
        let snapshot = try snapshot()
        for control in try cweCatalog().controls {
            let entry = try #require(snapshot.entries[control.id], "\(control.id) is not in the MITRE snapshot")
            #expect(control.title == entry.title, "\(control.id): '\(control.title)' is not MITRE's title")
        }
    }

    /// A finding should never carry an id MITRE says not to map to — CWE-20, 200, 400, 834 and
    /// the rest. Listing one in the catalogue would invite a rule to claim it.
    @Test("no catalogue id is one MITRE discourages or prohibits for mapping")
    func onlyMappableIds() throws {
        let snapshot = try snapshot()
        for control in try cweCatalog().controls {
            let usage = snapshot.entries[control.id]?.usage
            #expect(usage == "Allowed" || usage == "Allowed-with-Review",
                    "\(control.id) has mapping usage \(usage ?? "unknown")")
        }
    }

    // MARK: - The mapping

    @Test("rules outside the security.* family are mapped")
    func nonSecurityRulesAreMapped() {
        let mapped = Set(cweMappings().map(\.ruleId))
        for rule in ["force-unwrap", "fallback.int-conversion-unguarded",
                     "liveness.unbounded-wait", "infinite-loop", "keychain-secrets"] {
            #expect(mapped.contains(rule), "\(rule) has no CWE")
        }
    }

    /// The manifest embeds a CWE in every security diagnostic's message. Two places that can
    /// state a rule's weakness will, eventually, state two different ones.
    @Test("the security manifest and the mapping name the same CWE for each rule")
    func manifestAgreesWithMapping() throws {
        let mappings = cweMappings()
        for rule in SecurityRuleManifest.rules {
            let mapping = try #require(
                mappings.first { $0.ruleId == rule.ruleId },
                "\(rule.ruleId) is in the manifest and has no CWE mapping")
            let mappedIds = Set(mapping.satisfies.filter { $0.framework == "cwe" }.map(\.controlId))
            #expect(mappedIds == Set(rule.cwes),
                    "\(rule.ruleId): manifest says \(rule.cwes), mapping says \(mappedIds.sorted())")
        }
    }

    @Test("the shipped data, CWE included, has no phantom rule or control")
    func shippedDataIsValid() {
        let findings = ControlMappingValidator.validate(
            mappings: ControlMappingResources.mappings(),
            catalogs: ControlMappingResources.catalogs(),
            knownRuleIds: ControlMappingResources.registryRuleIds(),
            freshnessHorizonDays: 180,
            today: "2026-10-01")
        let errors = findings.filter { $0.severity == .error }.map(\.message)
        #expect(errors.isEmpty, "\(errors)")
    }

    // MARK: - Coverage, which is the point

    @Test("a weakness a rule reaches is reported as enforced, naming the rule")
    func enforcedRow() throws {
        let row = try #require(matrix().first { $0.controlId == "CWE-476" })
        #expect(row.state == .enforced)
        #expect(row.rules.contains("force-unwrap"))
    }

    /// Link following was a listed gap until the archive rules: a symlink an archive entry chose,
    /// created without checking where it points.
    @Test("CWE-59 is enforced by security.archive-symlink, and CWE-22 also by archive-path-escape")
    func archiveRulesCloseTheirRows() throws {
        let rows = matrix()
        let link = try #require(rows.first { $0.controlId == "CWE-59" })
        #expect(link.state == .enforced)
        #expect(link.rules == ["security.archive-symlink"])
        let traversal = try #require(rows.first { $0.controlId == "CWE-22" })
        #expect(traversal.rules.contains("security.archive-path-escape"))
    }

    /// The PRNG weaknesses were listed gaps until `ASeedIsNotASecret.md`; 336, 337 and 340 were
    /// not listed at all, and are added from MITRE 4.20 with the rules that reach them.
    @Test("the randomness weaknesses are enforced, each by its rule", arguments: [
        ("CWE-338", "security.weak-prng"),
        ("CWE-335", "security.seeded-secret"),
        ("CWE-336", "security.seeded-secret"),
        ("CWE-337", "security.seeded-secret"),
        ("CWE-341", "security.predictable-token"),
        ("CWE-340", "security.uuid-as-secret"),
    ])
    func randomnessRowsAreEnforced(cwe: String, rule: String) throws {
        let row = try #require(matrix().first { $0.controlId == cwe })
        #expect(row.state == .enforced)
        #expect(row.rules == [rule])
    }

    /// The reason to list a weakness nothing checks: the report then says so, every run,
    /// instead of the absence being something a person has to notice.
    @Test("a weakness the XML rules reach is enforced, and names them", arguments: [
        ("CWE-611", "security.xml-external-entities"),
        ("CWE-776", "security.xml-entity-expansion"),
    ])
    func xmlRowsAreEnforced(cwe: String, rule: String) throws {
        let row = try #require(matrix().first { $0.controlId == cwe })
        #expect(row.state == .enforced)
        #expect(row.rules == [rule])
    }

    @Test("a listed weakness no rule reaches is reported as a gap")
    func gapRow() throws {
        // CWE-611 was the example until `security.xml-external-entities` reached it; 789 is
        // a Phase 3 weakness (body limits), so it should stay a gap for a while yet.
        let row = try #require(matrix().first { $0.controlId == "CWE-789" })
        #expect(row.state == .gap)
        #expect(row.rules.isEmpty)
    }

    /// `ACipherIsItsArguments.md`: 327 had no rule once `weak-crypto` moved to 328, and 1240 had
    /// none at all. Each is now reached, and the row names the rule that reaches it.
    @Test("the cipher rules close CWE-327 and CWE-1240", arguments: [
        ("CWE-327", ["security.broken-cipher", "security.ecb-mode"]),
        ("CWE-1240", ["security.homemade-digest"]),
    ])
    func cipherGapsClose(cwe: String, rules: [String]) throws {
        let row = try #require(matrix().first { $0.controlId == cwe })
        #expect(row.state != .gap)
        #expect(Set(row.rules) == Set(rules))
    }

    /// The key rules: 321, 329, 916 and 326 were catalogued gaps; 1204 and 323 are added with
    /// the rule that reaches them, titles fetched from MITRE (CWE 4.20).
    @Test("the key rules close their weaknesses", arguments: [
        ("CWE-321", ["security.hardcoded-key"]),
        ("CWE-329", ["security.static-iv"]),
        ("CWE-1204", ["security.static-iv"]),
        ("CWE-323", ["security.static-iv"]),
        ("CWE-916", ["security.weak-kdf"]),
        ("CWE-326", ["security.weak-key-size"]),
    ])
    func keyGapsClose(cwe: String, rules: [String]) throws {
        let row = try #require(matrix().first { $0.controlId == cwe })
        #expect(row.state == .enforced)
        #expect(Set(row.rules) == Set(rules))
    }

    @Test("the catalogue records gaps as well as coverage")
    func catalogueIsNotOnlyWhatIsCovered() {
        let rows = matrix()
        #expect(rows.contains { $0.state == .enforced })
        #expect(rows.contains { $0.state == .gap })
    }

    /// Every weakness the CWE sweep and the 22 security proposals name is listed, so the report
    /// shows the size of the problem and not the subset first written down. It was 48 gaps; with
    /// the sweep's (d) and (e) rows and the proposals' mappings it is 137. The number will fall as
    /// rules land; it should not fall because ids were removed.
    @Test("the catalogue lists the sweep's and the proposals' weaknesses")
    func catalogueIsTheWholeList() throws {
        let ids = Set(try cweCatalog().controls.map(\.id))
        for id in ["CWE-917", "CWE-1427", "CWE-639", "CWE-1327", "CWE-88", "CWE-248", "CWE-187",
                   "CWE-606", "CWE-789", "CWE-1284", "CWE-611", "CWE-502", "CWE-1395"] {
            #expect(ids.contains(id), "\(id) is not catalogued")
        }
        // 130, less the four the key rules close (321, 326, 329, 916) and the three the randomness
        // rules close (335, 338, 341). 1204, 323, 336, 337 and 340 arrived already covered, so
        // they never counted as gaps.
        #expect(matrix().filter { $0.state == .gap }.count >= 123)
    }
}
