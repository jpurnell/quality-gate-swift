import Foundation
import Testing
@testable import NarrativeCore

@Suite("ProjectSharder — deterministic per-project shards")
struct ProjectSharderTests {
    private let sharder = ProjectSharder(maxSHAs: 3)

    private func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("Passing project renders header, status, score, trajectory")
    func passingProject() {
        let facts = ProjectFacts(
            projectID: "BusinessMathCharts",
            passing: true,
            overrideCount: 0,
            weightedScore: 0.870,
            tier: "active",
            trajectory: TrajectoryFacts(direction: "improving", slope: 0.0153, rSquared: 0.73, sampleSize: 14, inflectionDetected: false, recentSlope: nil)
        )
        let shard = sharder.shard(for: facts)
        #expect(shard.projectID == "BusinessMathCharts")
        #expect(shard.text.contains("# Project: BusinessMathCharts"))
        #expect(shard.text.contains("Status: PASSING; overrides=0"))
        #expect(shard.text.contains("Weighted score: 0.870 (tier active)"))
        #expect(shard.text.contains("Trajectory: improving slope=0.0153 r2=0.73 n=14"))
    }

    @Test("Failing project lists its failed checkers")
    func failingProject() {
        let facts = ProjectFacts(
            projectID: "Foo",
            passing: false,
            failedCheckers: ["test", "doc-lint"],
            overrideCount: 1
        )
        let shard = sharder.shard(for: facts)
        #expect(shard.text.contains("Status: FAILING: test, doc-lint; overrides=1"))
    }

    @Test("Work is capped to maxSHAs, most recent distinct SHAs first")
    func capsWorkToMaxSHAs() {
        let work = (1...5).map { i in
            WorkFacts(date: day("2026-07-0\(i)"), commitSHA: "sha\(i)", commitSubjects: ["commit \(i)"])
        }
        let facts = ProjectFacts(projectID: "Foo", passing: true, work: work)
        let shard = sharder.shard(for: facts)
        let shaLines = shard.text.split(whereSeparator: \.isNewline).filter { $0.contains("@sha") }
        #expect(shaLines.count == 3)
        // Most recent three are sha5, sha4, sha3 (date desc); sha1/sha2 dropped.
        #expect(shard.text.contains("@sha5"))
        #expect(shard.text.contains("@sha4"))
        #expect(shard.text.contains("@sha3"))
        #expect(!shard.text.contains("@sha1"))
        #expect(!shard.text.contains("@sha2"))
    }

    @Test("A project's shard contains no other project's data")
    func noCrossContamination() {
        let facts = ProjectFacts(
            projectID: "BusinessMath",
            passing: true,
            weightedScore: 0.937,
            work: [WorkFacts(date: day("2026-07-20"), commitSHA: "aaa111", commitSubjects: ["mine"])]
        )
        let shard = sharder.shard(for: facts)
        #expect(!shard.text.contains("BusinessMathCharts"))
        #expect(!shard.text.contains("@bbb222"))
    }

    @Test("Anomalies are capped and ordered by |z| descending")
    func anomaliesCappedAndOrdered() {
        let sharder = ProjectSharder(maxSHAs: 3, maxAnomalies: 2)
        let anomalies = [
            AnomalyFacts(metric: "low", direction: "positive", observedValue: 0.5, expectedValue: 0.1, zScore: 1.2, gatedSeverity: "confirmed", actionability: "monitor"),
            AnomalyFacts(metric: "high", direction: "positive", observedValue: 0.9, expectedValue: 0.1, zScore: 5.4, gatedSeverity: "confirmed", actionability: "investigate"),
            AnomalyFacts(metric: "mid", direction: "positive", observedValue: 0.7, expectedValue: 0.1, zScore: 3.1, gatedSeverity: "confirmed", actionability: "investigate"),
        ]
        let shard = sharder.shard(for: ProjectFacts(projectID: "Foo", passing: true, anomalies: anomalies))
        #expect(shard.text.contains("Anomalies (2):"))
        #expect(shard.text.contains("high positive"))
        #expect(shard.text.contains("mid positive"))
        #expect(!shard.text.contains("low positive"))
    }

    @Test("No work section when there are no work events")
    func noWorkSectionWhenEmpty() {
        let shard = sharder.shard(for: ProjectFacts(projectID: "Foo", passing: true))
        #expect(!shard.text.contains("Recent work"))
    }

    @Test("Sharding is deterministic — identical input yields identical output")
    func deterministic() {
        let facts = ProjectFacts(
            projectID: "Foo",
            passing: true,
            weightedScore: 0.9,
            trajectory: TrajectoryFacts(direction: "stable", slope: -0.001, rSquared: 0.2, sampleSize: 27, inflectionDetected: false, recentSlope: nil),
            work: [
                WorkFacts(date: day("2026-07-10"), commitSHA: "x", commitSubjects: ["a", "b"]),
                WorkFacts(date: day("2026-07-11"), commitSHA: "y", commitSubjects: ["c"]),
            ]
        )
        #expect(sharder.shard(for: facts).text == sharder.shard(for: facts).text)
    }

    @Test("shards(for:) sorts projects by ID for stable output")
    func shardsSortedByID() {
        let facts = [
            ProjectFacts(projectID: "Zeta", passing: true),
            ProjectFacts(projectID: "Alpha", passing: true),
            ProjectFacts(projectID: "Mango", passing: true),
        ]
        let ids = sharder.shards(for: facts).map(\.projectID)
        #expect(ids == ["Alpha", "Mango", "Zeta"])
    }
}
