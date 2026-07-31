import Foundation
import Testing
@testable import ControlMapping

/// Phase 1 — the compliance report renderer. Every rendering must lead with the
/// non-compliance disclaimer, list out-of-scope controls, and (JSON) round-trip.
@Suite("ComplianceReport")
struct ComplianceReportTests {

    private func shippedMatrix() -> [ControlCoverage] {
        ComplianceCoverage.matrix(
            catalogs: ControlMappingResources.catalogs(),
            mappings: ControlMappingResources.mappings(),
            knownRuleIds: ControlMappingResources.registryRuleIds())
    }

    @Test("terminal output leads with the non-compliance disclaimer")
    func terminalHasDisclaimer() {
        let out = ComplianceReport.render(shippedMatrix(), format: .terminal)
        #expect(out.contains("NOT an assertion of compliance"))
    }

    @Test("terminal output lists an enforced control with its rule, and the out-of-scope ones")
    func terminalListsControls() {
        let out = ComplianceReport.render(shippedMatrix(), format: .terminal)
        #expect(out.contains("164.312(e)(1)"))
        #expect(out.contains("security.insecure-transport"))
        #expect(out.contains("[out-of-scope]"))
        #expect(out.contains("164.312(b)"))     // audit controls — never hidden
    }

    @Test("json output is valid and round-trips the controls + disclaimer")
    func jsonRoundTrips() throws {
        let out = ComplianceReport.render(shippedMatrix(), format: .json)
        let data = try #require(out.data(using: .utf8))
        struct Decoded: Codable {
            let disclaimer: String
            let summary: [String: Int]
            let controls: [ControlCoverage]
        }
        let decoded = try JSONDecoder().decode(Decoded.self, from: data)
        #expect(decoded.disclaimer.contains("NOT an assertion of compliance"))
        #expect(decoded.controls.contains { $0.controlId == "164.312(e)(1)" && $0.state == .enforced })
        #expect(decoded.summary["out-of-scope"] == 2)
    }
}
