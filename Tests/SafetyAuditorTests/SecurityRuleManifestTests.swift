import Foundation
import Testing
@testable import SafetyAuditor

/// The manifest's shape.
///
/// It carried one CWE and one OWASP column, and the column's doc comment said Mobile. Every one
/// of the 22 security proposals dated 2026-10-01 had to work around that: server rules have no
/// honest Mobile category, and several rules are more than one weakness.
@Suite("Security rule manifest")
struct SecurityRuleManifestTests {

    @Test("Every rule names at least one CWE, each of the form CWE-<number>")
    func cwesAreWellFormed() {
        for rule in SecurityRuleManifest.rules {
            #expect(!rule.cwes.isEmpty, "\(rule.ruleId) names no CWE")
            for cwe in rule.cwes {
                let digits = cwe.dropFirst(4)
                #expect(cwe.hasPrefix("CWE-") && !digits.isEmpty && digits.allSatisfy(\.isNumber),
                        "\(rule.ruleId): '\(cwe)' is not CWE-<number>")
            }
            #expect(Set(rule.cwes).count == rule.cwes.count, "\(rule.ruleId) repeats a CWE")
        }
    }

    /// `cwe` stays as the primary, so every caller that read one string still reads the right one.
    @Test("The primary CWE is the first in the list")
    func primaryIsFirst() {
        for rule in SecurityRuleManifest.rules {
            #expect(rule.cwe == rule.cwes.first)
        }
    }

    @Test("A rule can carry more than one CWE")
    func tlsCarriesExpiration() throws {
        let tls = try #require(SecurityRuleManifest.rules.first { $0.ruleId == "security.tls-disabled" })
        #expect(tls.cwes == ["CWE-295", "CWE-298"])
    }

    /// Taken from MITRE's own OWASP Top Ten 2021 view (CWE 4.20), not recalled.
    @Test("Every shipped rule names its OWASP Top 10 2021 category", arguments: [
        ("security.hardcoded-secret", "A07:2021"),
        ("security.command-injection", "A03:2021"),
        ("security.weak-crypto", "A02:2021"),
        ("security.insecure-transport", "A02:2021"),
        ("security.eval-js", "A03:2021"),
        ("security.sql-injection", "A03:2021"),
        ("security.insecure-keychain", "A01:2021"),
        ("security.tls-disabled", "A07:2021"),
        ("security.path-traversal", "A01:2021"),
        ("security.ssrf", "A10:2021"),
        ("security.broken-cipher", "A02:2021"),
        ("security.ecb-mode", "A02:2021"),
        ("security.homemade-digest", "A02:2021"),
        ("security.xml-external-entities", "A05:2021"),
        ("security.xml-entity-expansion", "A05:2021"),
        ("security.archive-path-escape", "A01:2021"),
        ("security.archive-symlink", "A01:2021"),
        ("security.weak-prng", "A02:2021"),
        ("security.seeded-secret", "A02:2021"),
        ("security.predictable-token", "A02:2021"),
        ("security.uuid-as-secret", "A02:2021"),
    ])
    func top10Category(ruleId: String, category: String) throws {
        let rule = try #require(SecurityRuleManifest.rules.first { $0.ruleId == ruleId })
        let top10 = try #require(rule.owaspTop10, "\(ruleId) has no Top 10 category")
        #expect(top10.hasPrefix(category))
    }

    /// MITRE CWE 4.20: 22 is the parent of relative (23) and absolute (36) traversal, and an entry
    /// name can be either, so the parent is the accurate mapping. 59 is link following; 61 is the
    /// attack-oriented composite and is not used.
    @Test("The archive rules name the weaknesses they reach, at error", arguments: [
        ("security.archive-path-escape", ["CWE-22"]),
        ("security.archive-symlink", ["CWE-59"]),
    ])
    func archiveRules(ruleId: String, cwes: [String]) throws {
        let rule = try #require(SecurityRuleManifest.rules.first { $0.ruleId == ruleId })
        #expect(rule.cwes == cwes)
        #expect(rule.severity == "ERROR")
        #expect(rule.owaspMobile == "M4 Insufficient Input/Output Validation")
        #expect(rule.owaspAPI == nil)
    }

    /// Fetched from MITRE (CWE 4.20). 327 is a Class; its children were examined first and none
    /// fits "DES" or "ECB" — 328 is hashes, 916 is password KDFs, 780 is RSA padding.
    @Test("The cipher rules carry the CWE, severity and Mobile category the proposal fixed", arguments: [
        ("security.broken-cipher", "CWE-327", "ERROR"),
        ("security.ecb-mode", "CWE-327", "ERROR"),
        ("security.homemade-digest", "CWE-1240", "WARNING"),
    ])
    func cipherRules(ruleId: String, cwe: String, severity: String) throws {
        let rule = try #require(SecurityRuleManifest.rules.first { $0.ruleId == ruleId })
        #expect(rule.cwes == [cwe])
        #expect(rule.severity == severity)
        #expect(rule.owaspMobile == "M10 Insufficient Cryptography")
        #expect(rule.owaspTop10 == "A02:2021 Cryptographic Failures")
    }

    /// Fetched from MITRE (CWE 4.20) and in the committed snapshot. 330 is not used: MITRE marks it
    /// Discouraged. 340 is a Class kept after review — 341 is about observable state and 342/343
    /// about prediction from earlier values, and a v4 UUID is neither.
    @Test("The randomness rules carry the CWEs, severity and categories the proposal fixed", arguments: [
        ("security.weak-prng", ["CWE-338"], "ERROR"),
        ("security.seeded-secret", ["CWE-335", "CWE-336", "CWE-337"], "ERROR"),
        ("security.predictable-token", ["CWE-341"], "ERROR"),
        ("security.uuid-as-secret", ["CWE-340"], "WARNING"),
    ])
    func randomnessRules(ruleId: String, cwes: [String], severity: String) throws {
        let rule = try #require(SecurityRuleManifest.rules.first { $0.ruleId == ruleId })
        #expect(rule.cwes == cwes)
        #expect(rule.severity == severity)
        #expect(rule.owaspMobile == "M10 Insufficient Cryptography")
        #expect(rule.owaspTop10 == "A02:2021 Cryptographic Failures")
        #expect(rule.owaspAPI == nil)
    }

    @Test("The Mobile column keeps its value under its own name")
    func mobileColumn() {
        for rule in SecurityRuleManifest.rules {
            #expect(rule.owaspMobile.hasPrefix("M"))
        }
    }

    @Test("Mobile M4 is spelled the way OWASP spells it")
    func m4Title() {
        for rule in SecurityRuleManifest.rules where rule.owaspMobile.hasPrefix("M4") {
            #expect(rule.owaspMobile == "M4 Insufficient Input/Output Validation")
        }
    }

    @Test("The Semgrep export carries every CWE and every OWASP column present")
    func semgrepCarriesEverything() {
        let yaml = SecurityRuleManifest.semgrepYAML()
        for rule in SecurityRuleManifest.rules {
            for cwe in rule.cwes {
                #expect(yaml.contains(cwe), "\(rule.ruleId): \(cwe) missing from the export")
            }
            if let top10 = rule.owaspTop10 {
                #expect(yaml.contains(top10))
            }
        }
    }

    /// The proposal's table, recorded so the API column is not re-derived from memory.
    @Test("The XML rules carry their CWE, severity and API Security category", arguments: [
        ("security.xml-external-entities", "CWE-611", "ERROR", "API8:2023 Security Misconfiguration"),
        ("security.xml-entity-expansion", "CWE-776", "WARNING", "API4:2023 Unrestricted Resource Consumption"),
    ])
    func xmlRules(ruleId: String, cwe: String, severity: String, api: String) throws {
        let rule = try #require(SecurityRuleManifest.rules.first { $0.ruleId == ruleId })
        #expect(rule.cwes == [cwe])
        #expect(rule.severity == severity)
        #expect(rule.owaspAPI == api)
        #expect(rule.owaspTop10 == "A05:2021 Security Misconfiguration")
        #expect(rule.owaspMobile == "M4 Insufficient Input/Output Validation")
    }
}
