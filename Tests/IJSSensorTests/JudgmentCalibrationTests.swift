import Testing
import Foundation
@testable import IJSSensor

@Suite("JudgmentCalibration")
struct JudgmentCalibrationTests {

    static let sampleRCA = RootCauseAnalysis(
        proximateCause: "Bypassed ConcurrencyAuditor to ship feature on Friday",
        chainOfInquiry: [
            "AI-generated code wouldn't compile with strict concurrency",
            "Developer didn't understand Sendable requirements",
            "Decision was expedient rather than strategic",
        ],
        rootCause: "expedient",
        failedStep: .diagnosis,
        isRecurringPattern: false
    )

    static let sample = JudgmentCalibration(
        date: Date(timeIntervalSince1970: 1_777_536_311),
        decisionOwner: "j_doe_senior_dev",
        practitioner: "ai_agent_claude",
        riskTier: .safety,
        rootCauseAnalysis: sampleRCA,
        redTeamDissent: "Alternative: wrap the actor's mutable state in a struct. Counter: actor isolation is architecturally correct here.",
        proposedPolicyUpdate: "Add Sendable tutorial link to ConcurrencyAuditor failure message",
        pulseContribution: "Concurrency override driven by deadline pressure."
    )

    @Test("Golden path: all fields accessible")
    func goldenPath() {
        let cal = Self.sample
        #expect(cal.decisionOwner == "j_doe_senior_dev")
        #expect(cal.practitioner == "ai_agent_claude")
        #expect(cal.riskTier == .safety)
        #expect(cal.rootCauseAnalysis.rootCause == "expedient")
        #expect(cal.redTeamDissent.contains("Alternative"))
        #expect(cal.proposedPolicyUpdate == "Add Sendable tutorial link to ConcurrencyAuditor failure message")
        #expect(cal.pulseContribution.contains("deadline"))
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(Self.sample)
        let decoded = try decoder.decode(JudgmentCalibration.self, from: data)
        #expect(decoded == Self.sample)
    }

    @Test("camelCase JSON keys match MCP schema")
    func camelCaseKeys() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"decisionOwner\""))
        #expect(json.contains("\"riskTier\""))
        #expect(json.contains("\"rootCauseAnalysis\""))
        #expect(json.contains("\"redTeamDissent\""))
        #expect(json.contains("\"proposedPolicyUpdate\""))
        #expect(json.contains("\"pulseContribution\""))
    }

    @Test("JSON structure matches MCP REQUIRED STRUCTURE")
    func mcpStructure() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let data = try encoder.encode(Self.sample)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?.keys.contains("decisionOwner") == true)
        #expect(json?["decisionOwner"] as? String == "j_doe_senior_dev")
        #expect(json?["practitioner"] as? String == "ai_agent_claude")
        #expect(json?["riskTier"] as? Int == 3)
        #expect(json?["redTeamDissent"] as? String == "Alternative: wrap the actor's mutable state in a struct. Counter: actor isolation is architecturally correct here.")

        let rca = json?["rootCauseAnalysis"] as? [String: Any]
        #expect(rca?["proximateCause"] as? String == "Bypassed ConcurrencyAuditor to ship feature on Friday")
        #expect(rca?["rootCause"] as? String == "expedient")
        #expect(rca?["failedStep"] as? String == "diagnosis")
    }

    @Test("redTeamDissent is non-optional — compiler enforces presence")
    func redTeamDissentRequired() {
        let cal = JudgmentCalibration(
            date: Date(),
            decisionOwner: "owner",
            practitioner: "dev",
            riskTier: .informational,
            rootCauseAnalysis: RootCauseAnalysis(
                proximateCause: "test",
                chainOfInquiry: ["test"],
                rootCause: "test",
                failedStep: .doing,
                isRecurringPattern: false
            ),
            redTeamDissent: "AI review: no significant concerns, approach is sound.",
            proposedPolicyUpdate: nil,
            pulseContribution: "Minor style override."
        )
        #expect(cal.redTeamDissent.isEmpty == false)
    }

    @Test("proposedPolicyUpdate nil case")
    func nilPolicyUpdate() throws {
        let cal = JudgmentCalibration(
            date: Date(timeIntervalSince1970: 0),
            decisionOwner: "owner",
            practitioner: "dev",
            riskTier: .operational,
            rootCauseAnalysis: Self.sampleRCA,
            redTeamDissent: "No alternative identified.",
            proposedPolicyUpdate: nil,
            pulseContribution: "Test contribution."
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(cal)
        let decoded = try decoder.decode(JudgmentCalibration.self, from: data)
        #expect(decoded.proposedPolicyUpdate == nil)
    }

    @Test("proposedPolicyUpdate populated case")
    func populatedPolicyUpdate() {
        #expect(Self.sample.proposedPolicyUpdate == "Add Sendable tutorial link to ConcurrencyAuditor failure message")
    }

    @Test("Nested rootCauseAnalysis encodes and decodes")
    func nestedRCA() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(Self.sample)
        let decoded = try decoder.decode(JudgmentCalibration.self, from: data)
        #expect(decoded.rootCauseAnalysis == Self.sampleRCA)
        #expect(decoded.rootCauseAnalysis.chainOfInquiry.count == 3)
        #expect(decoded.rootCauseAnalysis.failedStep == .diagnosis)
    }

    @Test("All four risk tiers work")
    func allRiskTiers() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for tier in [RiskTier.informational, .operational, .safety, .critical] {
            let cal = JudgmentCalibration(
                date: Date(timeIntervalSince1970: 0),
                decisionOwner: "owner",
                practitioner: "dev",
                riskTier: tier,
                rootCauseAnalysis: Self.sampleRCA,
                redTeamDissent: "Reviewed.",
                proposedPolicyUpdate: nil,
                pulseContribution: "Test."
            )
            let data = try encoder.encode(cal)
            let decoded = try decoder.decode(JudgmentCalibration.self, from: data)
            #expect(decoded.riskTier == tier)
        }
    }

    @Test("Date encodes as ISO 8601")
    func dateEncoding() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Self.sample)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("2026-"))
    }
}
