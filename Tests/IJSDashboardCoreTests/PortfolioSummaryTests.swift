import Testing
import Foundation
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes

@Suite("PortfolioSummary")
struct PortfolioSummaryTests {
    @Test("Aggregates across projects")
    func aggregatesProjects() {
        let projects = [
            ProjectSummary.compute(projectID: "a", from: makePassingRuns(count: 3)),
            ProjectSummary.compute(projectID: "b", from: makeFailingRuns(count: 2)),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        #expect(portfolio.totalProjects == 2)
        #expect(portfolio.passingProjects == 1)
        #expect(portfolio.failingProjects == 1)
    }

    @Test("Identifies worst checkers across portfolio")
    func worstCheckers() {
        let runsA = makeRunsWithCheckers([
            ["safety": true, "build": false, "test": true],
        ])
        let runsB = makeRunsWithCheckers([
            ["safety": false, "build": false, "test": true],
        ])
        let projects = [
            ProjectSummary.compute(projectID: "a", from: runsA),
            ProjectSummary.compute(projectID: "b", from: runsB),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        #expect(portfolio.worstCheckers.first == "build")
    }

    @Test("Handles empty portfolio")
    func emptyPortfolio() {
        let portfolio = PortfolioSummary.compute(from: [])
        #expect(portfolio.totalProjects == 0)
        #expect(portfolio.passingProjects == 0)
    }
}

// MARK: - Helpers

private func makePassingRuns(count: Int) -> [TimestampedRun] {
    (0..<count).map { i in
        TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: "test",
                timestamp: Date(timeIntervalSince1970: Double(1747267200 + i * 3600)),
                environment: .local,
                decisionOwner: "test",
                results: [CheckResult(checkerId: "safety", status: .passed, diagnostics: [], duration: .milliseconds(100))],
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
        )
    }
}

private func makeFailingRuns(count: Int) -> [TimestampedRun] {
    (0..<count).map { i in
        TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: "test",
                timestamp: Date(timeIntervalSince1970: Double(1747267200 + i * 3600)),
                environment: .local,
                decisionOwner: "test",
                results: [CheckResult(checkerId: "build", status: .failed, diagnostics: [], duration: .milliseconds(100))],
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
        )
    }
}

private func makeRunsWithCheckers(_ checkerResults: [[String: Bool]]) -> [TimestampedRun] {
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
