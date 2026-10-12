import Foundation
import Testing
@testable import ControlMapping

/// `APatternIsAProgram.md`: CWE-1333, 943 and 917 were catalogued as gaps. The three pattern rules
/// reach them, and the compliance report should say which rule does.
@Suite("Pattern rules close their CWE rows")
struct PatternRuleMappingTests {

    private func row(_ cwe: String) throws -> ControlCoverage {
        let rows = ComplianceCoverage.matrix(
            catalogs: ControlMappingResources.catalogs(),
            mappings: ControlMappingResources.mappings(),
            knownRuleIds: ControlMappingResources.registryRuleIds()
        ).filter { $0.framework == "cwe" }
        return try #require(rows.first { $0.controlId == cwe }, "\(cwe) is not catalogued")
    }

    @Test("each pattern CWE is enforced, naming its rules", arguments: [
        ("CWE-1333", ["security.regex-catastrophic", "security.regex-from-input"]),
        ("CWE-943", ["security.predicate-injection"]),
        ("CWE-917", ["security.predicate-injection"]),
    ])
    func rowsClose(cwe: String, rules: [String]) throws {
        let coverage = try row(cwe)
        #expect(coverage.state == .enforced)
        #expect(Set(coverage.rules) == Set(rules))
    }
}
