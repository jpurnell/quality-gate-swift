import Testing
import Foundation
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes

@Suite("ProjectSummary")
struct ProjectSummaryTests {
    @Test("Computes pass rate correctly")
    func computesPassRate() {
        let runs = makeRuns(statuses: [true, true, false, true])
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(abs(summary.passRate - 0.75) < 1e-6)
    }

    @Test("Latest status reflects most recent run")
    func latestStatus() {
        let runs = makeRuns(statuses: [true, true, false])
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(summary.latestPassed == false)
    }

    @Test("Identifies worst-performing checker")
    func worstChecker() {
        let runs = makeRunsWithCheckers(
            checkerResults: [
                ["safety": true, "build": false],
                ["safety": true, "build": false],
                ["safety": false, "build": true],
            ]
        )
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(summary.worstChecker == "build")
    }

    @Test("Checker breakdown shows per-checker pass rates")
    func checkerBreakdown() {
        let runs = makeRunsWithCheckers(
            checkerResults: [
                ["safety": true, "build": false],
                ["safety": true, "build": true],
            ]
        )
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(abs(summary.checkerPassRates["safety"]! - 1.0) < 1e-6)
        #expect(abs(summary.checkerPassRates["build"]! - 0.5) < 1e-6)
    }

    @Test("Override count accumulates across runs")
    func overrideCount() {
        let runs = makeRuns(statuses: [true, true], overrideCountPerRun: 3)
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(summary.totalOverrides == 6)
    }

    @Test("Handles single run")
    func singleRun() {
        let runs = makeRuns(statuses: [true])
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(abs(summary.passRate - 1.0) < 1e-6)
        #expect(summary.runCount == 1)
    }

    @Test("Handles empty runs")
    func emptyRuns() {
        let summary = ProjectSummary.compute(projectID: "test", from: [])
        #expect(abs(summary.passRate) < 1e-6)
        #expect(summary.runCount == 0)
    }
}

// MARK: - Helpers

private func makeRuns(statuses: [Bool], overrideCountPerRun: Int = 0) -> [TimestampedRun] {
    statuses.enumerated().map { index, allPassed in
        let overrides = (0..<overrideCountPerRun).map { _ in
            OverrideRecord(
                diagnosticOverride: DiagnosticOverride(ruleId: "test", justification: "test", filePath: "f.swift", lineNumber: 1),
                author: "test",
                riskTier: .operational,
                authorityLevel: .peer
            )
        }
        return TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: "test",
                timestamp: Date(timeIntervalSince1970: Double(1747267200 + index * 3600)),
                environment: .local,
                decisionOwner: "test",
                results: [
                    CheckResult(
                        checkerId: "safety",
                        status: allPassed ? .passed : .failed,
                        diagnostics: [],
                        duration: .milliseconds(100)
                    ),
                ],
                overrides: overrides,
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
        )
    }
}

private func makeRunsWithCheckers(checkerResults: [[String: Bool]]) -> [TimestampedRun] {
    checkerResults.enumerated().map { index, checkers in
        let results = checkers.map { id, passed in
            CheckResult(
                checkerId: id,
                status: passed ? .passed : .failed,
                diagnostics: [],
                duration: .milliseconds(100)
            )
        }
        return TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: "test",
                timestamp: Date(timeIntervalSince1970: Double(1747267200 + index * 3600)),
                environment: .local,
                decisionOwner: "test",
                results: results,
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
        )
    }
}
