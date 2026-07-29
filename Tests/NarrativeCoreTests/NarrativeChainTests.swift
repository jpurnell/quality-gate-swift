import Foundation
import Testing
import CorpusKit
@testable import NarrativeCore

@Suite("NarrativeChain — durability fallback order")
struct NarrativeChainTests {
    // MARK: - Fixtures

    private func makeInput() -> NarrativeInput {
        let stats = PulseStatistics(
            totalGateRuns: 0,
            passedRuns: 0,
            failedRuns: 0,
            totalOverrides: 0,
            totalCalibrations: 0,
            corpusTrends: [],
            projectTrends: [:],
            anomalies: []
        )
        let pulse = InstitutionalPulse(
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 86_400),
            weekLabel: "2026-W30",
            label: "2026-07-29",
            projects: ["Foo"],
            statistics: stats,
            violationClusters: [],
            proposedPolicyUpdates: [],
            calibrationSummaries: [],
            narrative: nil,
            generatedAt: Date(timeIntervalSince1970: 86_400)
        )
        return NarrativeInput(pulse: pulse, previousPulse: nil, workLogsByProject: [:])
    }

    private struct MockError: Error {}

    private struct MockProvider: NarrativeProvider {
        let source: ProseSource
        var available: Bool = true
        /// `nil` output means `narrate` throws.
        var output: String? = "narrative"
        func isAvailable(for input: NarrativeInput) -> Bool { available }
        func narrate(_ input: NarrativeInput) async throws -> String {
            guard let output else { throw MockError() }
            return output
        }
    }

    // MARK: - Tests

    @Test("Primary succeeds → primary result and source")
    func primaryWins() async {
        let chain = NarrativeChain(providers: [
            MockProvider(source: .claude, output: "from-claude"),
            MockProvider(source: .onDeviceLLM, output: "from-fm"),
        ])
        let result = await chain.narrate(makeInput())
        #expect(result?.source == .claude)
        #expect(result?.text == "from-claude")
    }

    @Test("Unavailable primary is skipped → next available rung")
    func unavailablePrimarySkipped() async {
        let chain = NarrativeChain(providers: [
            MockProvider(source: .claude, available: false, output: "from-claude"),
            MockProvider(source: .onDeviceLLM, output: "from-fm"),
        ])
        let result = await chain.narrate(makeInput())
        #expect(result?.source == .onDeviceLLM)
        #expect(result?.text == "from-fm")
    }

    @Test("Throwing primary demotes to the next rung")
    func throwingPrimaryDemotes() async {
        let chain = NarrativeChain(providers: [
            MockProvider(source: .claude, output: nil),
            MockProvider(source: .onDeviceLLM, output: "from-fm"),
        ])
        let result = await chain.narrate(makeInput())
        #expect(result?.source == .onDeviceLLM)
    }

    @Test("Empty output demotes to the next rung")
    func emptyOutputDemotes() async {
        let chain = NarrativeChain(providers: [
            MockProvider(source: .claude, output: "   \n  "),
            MockProvider(source: .onDeviceLLM, output: "from-fm"),
        ])
        let result = await chain.narrate(makeInput())
        #expect(result?.source == .onDeviceLLM)
    }

    @Test("Full chain: Claude throws, FM unavailable → preserved rung wins")
    func fallsAllTheWayToPreserved() async {
        let chain = NarrativeChain(providers: [
            MockProvider(source: .claude, output: nil),
            MockProvider(source: .onDeviceLLM, available: false),
            MockProvider(source: .preservedLLM, output: "carried-forward"),
        ])
        let result = await chain.narrate(makeInput())
        #expect(result?.source == .preservedLLM)
        #expect(result?.text == "carried-forward")
    }

    @Test("No provider can run → nil")
    func noProviderRuns() async {
        let chain = NarrativeChain(providers: [
            MockProvider(source: .claude, available: false),
            MockProvider(source: .onDeviceLLM, output: nil),
        ])
        let result = await chain.narrate(makeInput())
        #expect(result == nil)
    }
}
