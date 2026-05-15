import Testing
import Foundation
@testable import IJSSensor

@Suite("FiveStepStage")
struct FiveStepStageTests {

    @Test("All five cases exist with correct raw values")
    func rawValues() {
        #expect(FiveStepStage.goals.rawValue == "goals")
        #expect(FiveStepStage.problems.rawValue == "problems")
        #expect(FiveStepStage.diagnosis.rawValue == "diagnosis")
        #expect(FiveStepStage.design.rawValue == "design")
        #expect(FiveStepStage.doing.rawValue == "doing")
    }

    @Test("Codable round-trip for each case")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let allCases: [FiveStepStage] = [.goals, .problems, .diagnosis, .design, .doing]
        for stage in allCases {
            let data = try encoder.encode(stage)
            let decoded = try decoder.decode(FiveStepStage.self, from: data)
            #expect(decoded == stage)
        }
    }

    @Test("Encodes as quoted string")
    func encodesAsString() throws {
        let data = try JSONEncoder().encode(FiveStepStage.diagnosis)
        let jsonString = String(data: data, encoding: .utf8)
        #expect(jsonString == "\"diagnosis\"")
    }
}
