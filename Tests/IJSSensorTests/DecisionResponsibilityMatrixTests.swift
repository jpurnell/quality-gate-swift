import Testing
import Foundation
@testable import IJSSensor

@Suite("RoleAssignment")
struct RoleAssignmentTests {

    @Test("Stores name, role, and required action")
    func properties() {
        let assignment = RoleAssignment(
            name: "Jane Doe",
            role: "Lead Engineer",
            requiredAction: "Approval of Step 0 Proposal"
        )
        #expect(assignment.name == "Jane Doe")
        #expect(assignment.role == "Lead Engineer")
        #expect(assignment.requiredAction == "Approval of Step 0 Proposal")
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let assignment = RoleAssignment(
            name: "Jane Doe",
            role: "Lead Engineer",
            requiredAction: "Approval of Step 0 Proposal"
        )
        let data = try JSONEncoder().encode(assignment)
        let decoded = try JSONDecoder().decode(RoleAssignment.self, from: data)
        #expect(decoded == assignment)
    }
}

@Suite("DecisionResponsibilityMatrix")
struct DecisionResponsibilityMatrixTests {

    static let sample = DecisionResponsibilityMatrix(
        architecturalSignoff: RoleAssignment(
            name: "Alice", role: "Architect", requiredAction: "Approve Step 0"
        ),
        overrideAuthority: RoleAssignment(
            name: "Bob", role: "Security Lead", requiredAction: "Approve Tier 2+ bypass"
        ),
        redTeamChallenge: RoleAssignment(
            name: "Carol", role: "Senior Dev", requiredAction: "Formal dissent review"
        ),
        finalShippingRights: RoleAssignment(
            name: "Dave", role: "VP Engineering", requiredAction: "Prototype to Product decision"
        ),
        assignedRiskTier: .safety,
        contextualConstraints: ["Handles PII", "GDPR consent required"]
    )

    @Test("Golden path: all fields accessible")
    func goldenPath() {
        let drm = Self.sample
        #expect(drm.architecturalSignoff.name == "Alice")
        #expect(drm.overrideAuthority.role == "Security Lead")
        #expect(drm.redTeamChallenge.requiredAction == "Formal dissent review")
        #expect(drm.finalShippingRights.name == "Dave")
        #expect(drm.assignedRiskTier == .safety)
        #expect(drm.contextualConstraints.count == 2)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let decoded = try JSONDecoder().decode(DecisionResponsibilityMatrix.self, from: data)
        #expect(decoded == Self.sample)
    }

    @Test("JSON keys use camelCase")
    func camelCaseKeys() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"architecturalSignoff\""))
        #expect(json.contains("\"overrideAuthority\""))
        #expect(json.contains("\"redTeamChallenge\""))
        #expect(json.contains("\"finalShippingRights\""))
        #expect(json.contains("\"assignedRiskTier\""))
        #expect(json.contains("\"contextualConstraints\""))
    }

    @Test("Empty contextual constraints")
    func emptyConstraints() throws {
        let drm = DecisionResponsibilityMatrix(
            architecturalSignoff: RoleAssignment(name: "A", role: "R", requiredAction: "X"),
            overrideAuthority: RoleAssignment(name: "B", role: "R", requiredAction: "X"),
            redTeamChallenge: RoleAssignment(name: "C", role: "R", requiredAction: "X"),
            finalShippingRights: RoleAssignment(name: "D", role: "R", requiredAction: "X"),
            assignedRiskTier: .informational,
            contextualConstraints: []
        )
        let data = try JSONEncoder().encode(drm)
        let decoded = try JSONDecoder().decode(DecisionResponsibilityMatrix.self, from: data)
        #expect(decoded.contextualConstraints.isEmpty)
    }

    @Test("Contextual constraints preserve order")
    func constraintOrder() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let decoded = try JSONDecoder().decode(DecisionResponsibilityMatrix.self, from: data)
        #expect(decoded.contextualConstraints[0] == "Handles PII")
        #expect(decoded.contextualConstraints[1] == "GDPR consent required")
    }

    @Test("Risk tier integrates with RiskTier enum")
    func riskTierIntegration() {
        #expect(Self.sample.assignedRiskTier.requiredAuthority == .decisionOwner)
    }
}
