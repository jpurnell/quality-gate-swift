import Testing
import Foundation
import QualityGateTypes
@testable import IJSRefiner
import IJSSensor
import IJSAggregator

@Suite("PulseRefiner Metadata Filtering")
struct MetadataFilterTests {

    private let writer = TelemetryWriter()

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeMetadata(
        projectID: String = "test-project",
        timestamp: Date,
        checkerCount: Int = 20,
        failedCheckerIds: [String] = []
    ) -> CheckResultMetadata {
        var results: [CheckResult] = []
        let failedSet = Set(failedCheckerIds)
        let checkerNames = [
            "build", "test", "safety", "doc-lint", "doc-coverage",
            "unreachable", "recursion", "concurrency", "pointer-escape",
            "memory-builder", "accessibility", "status", "swift-version",
            "logging", "test-quality", "context", "dependency-audit",
            "release-readiness", "fp-safety", "complexity",
        ]
        for i in 0..<checkerCount {
            let name = i < checkerNames.count ? checkerNames[i] : "checker-\(i)"
            let failed = failedSet.contains(name)
            results.append(CheckResult(
                checkerId: name,
                status: failed ? .failed : .passed,
                diagnostics: [],
                duration: .zero
            ))
        }
        return CheckResultMetadata(
            projectID: projectID,
            timestamp: timestamp,
            environment: .local,
            decisionOwner: "test",
            results: results,
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil
        )
    }

    // MARK: - Partial Run Filtering

    @Test("Filters out single-checker debug runs")
    func filtersSingleCheckerRuns() async throws {
        let refiner = PulseRefiner(writer: writer)
        let metadata: [String: [CheckResultMetadata]] = [
            "proj": [
                makeMetadata(timestamp: makeDate("2026-05-26T03:25:13"), checkerCount: 1),
                makeMetadata(timestamp: makeDate("2026-05-26T03:27:06"), checkerCount: 1),
                makeMetadata(timestamp: makeDate("2026-05-26T17:48:57"), checkerCount: 20),
            ]
        ]
        let filtered = await refiner.filterMetadataForScoring(metadata)
        let runs = try #require(filtered["proj"])
        #expect(runs.count == 1)
        #expect(runs[0].results.count == 20)
    }

    @Test("Keeps runs with exactly minimumCheckerCount checkers")
    func keepsBoundaryCheckerCount() async throws {
        let refiner = PulseRefiner(writer: writer)
        let metadata: [String: [CheckResultMetadata]] = [
            "proj": [
                makeMetadata(timestamp: makeDate("2026-05-26T10:00:00"), checkerCount: 4),
                makeMetadata(timestamp: makeDate("2026-05-26T11:00:00"), checkerCount: 5),
            ]
        ]
        let filtered = await refiner.filterMetadataForScoring(metadata)
        let runs = try #require(filtered["proj"])
        #expect(runs.count == 1)
        #expect(runs[0].results.count == 5)
    }

    @Test("All partial runs removes project from scoring")
    func allPartialRemovesProject() async {
        let refiner = PulseRefiner(writer: writer)
        let metadata: [String: [CheckResultMetadata]] = [
            "proj": [
                makeMetadata(timestamp: makeDate("2026-05-26T03:25:13"), checkerCount: 1),
                makeMetadata(timestamp: makeDate("2026-05-26T03:27:06"), checkerCount: 2),
            ]
        ]
        let filtered = await refiner.filterMetadataForScoring(metadata)
        #expect(filtered["proj"] == nil)
    }

    // MARK: - Daily Deduplication

    @Test("Keeps only latest run per calendar day")
    func deduplicatesToLatestPerDay() async throws {
        let refiner = PulseRefiner(writer: writer)
        let metadata: [String: [CheckResultMetadata]] = [
            "proj": [
                makeMetadata(timestamp: makeDate("2026-05-26T03:25:13"), checkerCount: 20,
                             failedCheckerIds: ["unreachable"]),
                makeMetadata(timestamp: makeDate("2026-05-26T10:00:00"), checkerCount: 20,
                             failedCheckerIds: ["unreachable"]),
                makeMetadata(timestamp: makeDate("2026-05-26T17:48:57"), checkerCount: 20),
            ]
        ]
        let filtered = await refiner.filterMetadataForScoring(metadata)
        let runs = try #require(filtered["proj"])
        #expect(runs.count == 1)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        #expect(fmt.string(from: runs[0].timestamp) == "17:48:57")
    }

    @Test("Preserves runs across different days")
    func preservesDifferentDays() async throws {
        let refiner = PulseRefiner(writer: writer)
        let metadata: [String: [CheckResultMetadata]] = [
            "proj": [
                makeMetadata(timestamp: makeDate("2026-05-25T10:00:00"), checkerCount: 20),
                makeMetadata(timestamp: makeDate("2026-05-26T10:00:00"), checkerCount: 20),
                makeMetadata(timestamp: makeDate("2026-05-27T10:00:00"), checkerCount: 20),
            ]
        ]
        let filtered = await refiner.filterMetadataForScoring(metadata)
        let runs = try #require(filtered["proj"])
        #expect(runs.count == 3)
    }

    @Test("Sorts deduplicated runs chronologically")
    func sortedChronologically() async throws {
        let refiner = PulseRefiner(writer: writer)
        let metadata: [String: [CheckResultMetadata]] = [
            "proj": [
                makeMetadata(timestamp: makeDate("2026-05-27T10:00:00"), checkerCount: 20),
                makeMetadata(timestamp: makeDate("2026-05-25T10:00:00"), checkerCount: 20),
                makeMetadata(timestamp: makeDate("2026-05-26T10:00:00"), checkerCount: 20),
            ]
        ]
        let filtered = await refiner.filterMetadataForScoring(metadata)
        let runs = try #require(filtered["proj"])
        #expect(runs.count == 3)
        #expect(runs[0].timestamp < runs[1].timestamp)
        #expect(runs[1].timestamp < runs[2].timestamp)
    }

    // MARK: - Combined Filtering

    @Test("WineTaster 4 scenario: 23 runs, most partial, produces clean score")
    func wineTasterScenario() async throws {
        let refiner = PulseRefiner(writer: writer)
        var runs: [CheckResultMetadata] = []
        // 1 pass with 1 checker (debug)
        runs.append(makeMetadata(timestamp: makeDate("2026-05-26T02:56:18"), checkerCount: 1))
        // 4 full-suite runs with unreachable failing
        for ts in ["03:25:13", "03:27:06", "17:09:53", "17:12:11"] {
            runs.append(makeMetadata(timestamp: makeDate("2026-05-26T\(ts)"), checkerCount: 19,
                                     failedCheckerIds: ["unreachable"]))
        }
        // 12 single-checker debug runs (failing)
        for i in 0..<12 {
            let minute = 37 + i
            runs.append(makeMetadata(timestamp: makeDate("2026-05-26T03:\(minute):00"), checkerCount: 1,
                                     failedCheckerIds: ["unreachable"]))
        }
        // 1 final pass with 1 checker
        runs.append(makeMetadata(timestamp: makeDate("2026-05-26T17:48:57"), checkerCount: 1))
        // 1 actual clean full-suite run at the end
        runs.append(makeMetadata(timestamp: makeDate("2026-05-26T18:00:00"), checkerCount: 20))

        let metadata = ["WineTaster 4": runs]
        let filtered = await refiner.filterMetadataForScoring(metadata)
        let filteredRuns = try #require(filtered["WineTaster 4"])
        // All on same day, so only 1 run kept (the latest full-suite: 18:00:00)
        #expect(filteredRuns.count == 1)
        #expect(filteredRuns[0].results.count == 20)
        // Score should be 1.0 since all checkers pass
        let score = SeverityWeight.weightedScore(
            checkerResults: filteredRuns[0].results.map { ($0.checkerId, $0.status == .passed) }
        )
        #expect(abs(score - 1.0) < 1e-10)
    }
}
