import Foundation
import Testing
import CorpusKit
@testable import NarrativeCore

@Suite("ProjectFactsExtractor — per-project isolation from the pulse")
struct ProjectFactsExtractorTests {
    private let extractor = ProjectFactsExtractor()

    private func twoProjectInput() -> NarrativeInput {
        let snapshot = CurrentSnapshot(
            projects: [
                PulseFixtures.status("BusinessMath", passing: true, overrideCount: 1),
                PulseFixtures.status("BusinessMathCharts", passing: false, failedCheckers: ["test"]),
            ],
            totalOverrides: 1,
            totalComplianceCount: 0,
            failingCheckers: ["test": 1]
        )
        let pulse = PulseFixtures.pulse(
            projects: ["BusinessMath", "BusinessMathCharts"],
            statistics: PulseFixtures.emptyStats(
                weightedScores: ["BusinessMath": 0.937, "BusinessMathCharts": 0.870],
                gatedAnomalies: [
                    PulseFixtures.anomaly(scope: "BusinessMath", metric: "overrideRate", z: 2.4),
                    PulseFixtures.anomaly(scope: "BusinessMathCharts", metric: "passRate", z: 5.1),
                ]
            ),
            projectTiers: ["BusinessMath": .active, "BusinessMathCharts": .active],
            projectTrajectories: [
                ProjectTrajectory(projectID: "BusinessMathCharts", slope: 0.0153, intercept: 0.8, rSquared: 0.73, sampleSize: 14, validity: .preliminary, direction: .improving),
            ],
            currentSnapshot: snapshot
        )
        let work: [String: [WorkEvent]] = [
            "BusinessMath": [WorkEvent(date: PulseFixtures.day("2026-07-20"), commitSHA: "aaa111", commitSubjects: ["math work"], changelogDelta: nil, sessionSummary: nil)],
            "BusinessMathCharts": [WorkEvent(date: PulseFixtures.day("2026-07-21"), commitSHA: "ccc333", commitSubjects: ["charts work"], changelogDelta: nil, sessionSummary: nil)],
        ]
        return NarrativeInput(pulse: pulse, previousPulse: nil, workLogsByProject: work)
    }

    @Test("Extracts status, score, tier, trajectory, anomalies, and work per project")
    func extractsAllFields() {
        let facts = extractor.facts(from: twoProjectInput())
        #expect(facts.count == 2)
        let charts = try? #require(facts.first { $0.projectID == "BusinessMathCharts" })
        #expect(charts?.passing == false)
        #expect(charts?.failedCheckers == ["test"])
        #expect(abs((charts?.weightedScore ?? -1) - 0.870) < 1e-6)
        #expect(charts?.tier == "active")
        #expect(charts?.trajectory?.direction == "improving")
        #expect(charts?.trajectory?.sampleSize == 14)
        #expect(charts?.anomalies.count == 1)
        #expect(charts?.anomalies.first?.metric == "passRate")
        #expect(charts?.work.first?.commitSHA == "ccc333")
    }

    @Test("A project's facts contain none of a sibling's anomalies or work")
    func noCrossContamination() {
        let facts = extractor.facts(from: twoProjectInput())
        let math = facts.first { $0.projectID == "BusinessMath" }
        // BusinessMath must carry only its own anomaly (overrideRate) and its own commit.
        #expect(math?.anomalies.allSatisfy { $0.metric == "overrideRate" } == true)
        #expect(math?.work.allSatisfy { $0.commitSHA == "aaa111" } == true)
        #expect(math?.work.contains { $0.commitSHA == "ccc333" } == false)
        #expect(abs((math?.weightedScore ?? -1) - 0.937) < 1e-6)
    }

    @Test("Anomalies are matched to a project by scope, not by order")
    func anomaliesMatchedByScope() {
        let facts = extractor.facts(from: twoProjectInput())
        for f in facts {
            #expect(f.anomalies.isEmpty == false)
        }
        // The high-z passRate anomaly belongs to Charts, the overrideRate to Math.
        #expect(abs((facts.first { $0.projectID == "BusinessMathCharts" }?.anomalies.first?.zScore ?? -1) - 5.1) < 1e-6)
        #expect(abs((facts.first { $0.projectID == "BusinessMath" }?.anomalies.first?.zScore ?? -1) - 2.4) < 1e-6)
    }

    @Test("A project present only in weightedScores still appears, defaulting to passing")
    func projectUniverseIsUnion() {
        let pulse = PulseFixtures.pulse(
            statistics: PulseFixtures.emptyStats(weightedScores: ["Orphan": 0.9])
        )
        let facts = extractor.facts(from: NarrativeInput(pulse: pulse, previousPulse: nil, workLogsByProject: [:]))
        let orphan = facts.first { $0.projectID == "Orphan" }
        #expect(orphan?.projectID == "Orphan")
        #expect(orphan?.passing == true)          // no snapshot → default passing
        #expect(abs((orphan?.weightedScore ?? -1) - 0.9) < 1e-6)
        #expect(orphan?.anomalies.isEmpty == true)
    }

    @Test("Facts are returned sorted by project ID")
    func sortedByID() {
        let pulse = PulseFixtures.pulse(
            statistics: PulseFixtures.emptyStats(weightedScores: ["Zeta": 0.9, "Alpha": 0.8, "Mango": 0.85])
        )
        let ids = extractor.facts(from: NarrativeInput(pulse: pulse, previousPulse: nil, workLogsByProject: [:])).map(\.projectID)
        #expect(ids == ["Alpha", "Mango", "Zeta"])
    }
}
