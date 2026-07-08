import Testing
import Foundation
@testable import IJSSensor

@Suite("ModuleOrientationCard")
struct ModuleOrientationCardTests {

    private let fixedDate = Date(timeIntervalSince1970: 1_777_536_311)

    private func sampleCard(id: String = "IJSSensor", reliedOnBy: [String] = ["IJSAggregator", "IJSRefiner"]) -> ModuleOrientationCard {
        ModuleOrientationCard(
            moduleID: id,
            whatItDoes: "Captures IJS telemetry.",
            why: "Central data source the analytics build on.",
            reliedOnBy: reliedOnBy,
            role: "foundation",
            source: .template,
            generatedAt: fixedDate
        )
    }

    @Test("card round-trips through Codable losslessly")
    func cardRoundTrip() throws {
        let card = sampleCard()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(card)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModuleOrientationCard.self, from: data)
        #expect(decoded == card)
    }

    @Test("nil prose fields encode and decode as nil")
    func nilProse() throws {
        let card = ModuleOrientationCard(
            moduleID: "M", whatItDoes: nil, why: nil,
            reliedOnBy: [], role: "isolated", source: .template, generatedAt: fixedDate
        )
        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(ModuleOrientationCard.self, from: data)
        #expect(decoded.whatItDoes == nil)
        #expect(decoded.why == nil)
        #expect(decoded.reliedOnBy.isEmpty)
    }

    @Test("report finds a module's card by id")
    func reportLookup() {
        let report = OrientationReport(
            projectID: "quality-gate-swift",
            timestamp: fixedDate,
            cards: [sampleCard(id: "IJSSensor"), sampleCard(id: "IJSAggregator")]
        )
        #expect(report.card(for: "IJSSensor")?.moduleID == "IJSSensor")
        #expect(report.card(for: "IJSAggregator")?.moduleID == "IJSAggregator")
        #expect(report.card(for: "Nonexistent") == nil)
    }

    @Test("report round-trips through Codable")
    func reportRoundTrip() throws {
        let report = OrientationReport(
            projectID: "pkg", timestamp: fixedDate,
            cards: [sampleCard()]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(OrientationReport.self, from: data)
        #expect(decoded == report)
    }
}
