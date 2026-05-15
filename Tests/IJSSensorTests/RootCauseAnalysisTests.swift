import Testing
import Foundation
@testable import IJSSensor

@Suite("RootCauseAnalysis")
struct RootCauseAnalysisTests {

    static let sample = RootCauseAnalysis(
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

    @Test("Golden path: all fields accessible after creation")
    func goldenPath() {
        let rca = Self.sample
        #expect(rca.proximateCause == "Bypassed ConcurrencyAuditor to ship feature on Friday")
        #expect(rca.chainOfInquiry.count == 3)
        #expect(rca.rootCause == "expedient")
        #expect(rca.failedStep == .diagnosis)
        #expect(rca.isRecurringPattern == false)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(Self.sample)
        let decoded = try decoder.decode(RootCauseAnalysis.self, from: data)
        #expect(decoded == Self.sample)
    }

    @Test("JSON keys use camelCase")
    func camelCaseKeys() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"proximateCause\""))
        #expect(json.contains("\"chainOfInquiry\""))
        #expect(json.contains("\"rootCause\""))
        #expect(json.contains("\"failedStep\""))
        #expect(json.contains("\"isRecurringPattern\""))
    }

    @Test("Chain of inquiry preserves order")
    func chainOrder() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let decoded = try JSONDecoder().decode(RootCauseAnalysis.self, from: data)
        #expect(decoded.chainOfInquiry[0].contains("compile"))
        #expect(decoded.chainOfInquiry[1].contains("Sendable"))
        #expect(decoded.chainOfInquiry[2].contains("expedient"))
    }

    @Test("Single-entry chain of inquiry")
    func singleEntryChain() throws {
        let rca = RootCauseAnalysis(
            proximateCause: "Used force unwrap",
            chainOfInquiry: ["Developer was rushing"],
            rootCause: "hasty",
            failedStep: .doing,
            isRecurringPattern: true
        )
        let data = try JSONEncoder().encode(rca)
        let decoded = try JSONDecoder().decode(RootCauseAnalysis.self, from: data)
        #expect(decoded.chainOfInquiry.count == 1)
        #expect(decoded == rca)
    }

    @Test("All five FiveStepStage values encode correctly in RCA")
    func allStages() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let stages: [FiveStepStage] = [.goals, .problems, .diagnosis, .design, .doing]

        for stage in stages {
            let rca = RootCauseAnalysis(
                proximateCause: "test",
                chainOfInquiry: ["test"],
                rootCause: "test",
                failedStep: stage,
                isRecurringPattern: false
            )
            let data = try encoder.encode(rca)
            let decoded = try decoder.decode(RootCauseAnalysis.self, from: data)
            #expect(decoded.failedStep == stage)
        }
    }

    @Test("isRecurringPattern true case")
    func recurringTrue() {
        let rca = RootCauseAnalysis(
            proximateCause: "Repeated override",
            chainOfInquiry: ["Same pattern as last sprint"],
            rootCause: "systemic",
            failedStep: .problems,
            isRecurringPattern: true
        )
        #expect(rca.isRecurringPattern == true)
    }
}
