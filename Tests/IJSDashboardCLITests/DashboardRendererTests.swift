import Testing
import Foundation
@testable import IJSDashboardCLI
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes

@Suite("DashboardRenderer")
struct DashboardRendererTests {

    // MARK: - Portfolio View

    @Test("Renders portfolio header with project counts")
    func portfolioHeader() {
        let portfolio = makePortfolio(total: 5, passing: 3, failing: 2)
        let output = DashboardRenderer.renderPortfolio(portfolio, projects: [])
        #expect(output.contains("5 projects"))
        #expect(output.contains("3 passing"))
        #expect(output.contains("2 failing"))
    }

    @Test("Renders project rows with pass rate and status")
    func projectRows() {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0, latestPassed: true),
            makeProjectSummary(id: "beta", passRate: 0.5, latestPassed: false),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        let output = DashboardRenderer.renderPortfolio(portfolio, projects: projects)
        #expect(output.contains("alpha"))
        #expect(output.contains("beta"))
        #expect(output.contains("100%"))
        #expect(output.contains("50%"))
    }

    @Test("Renders worst checkers in portfolio")
    func worstCheckers() {
        let projects = [
            makeProjectSummary(id: "a", passRate: 0.5, latestPassed: false, checkerRates: ["build": 0.0, "safety": 1.0]),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        let output = DashboardRenderer.renderPortfolio(portfolio, projects: projects)
        #expect(output.contains("build"))
    }

    @Test("Renders empty portfolio gracefully")
    func emptyPortfolio() {
        let portfolio = PortfolioSummary.compute(from: [])
        let output = DashboardRenderer.renderPortfolio(portfolio, projects: [])
        #expect(output.contains("0 projects"))
    }

    // MARK: - Project Detail View

    @Test("Renders project detail with pass rate and run count")
    func projectDetail() {
        let summary = makeProjectSummary(id: "quality-gate-swift", passRate: 0.85, latestPassed: true, runCount: 20)
        let output = DashboardRenderer.renderProjectDetail(summary, trends: [])
        #expect(output.contains("quality-gate-swift"))
        #expect(output.contains("85%"))
        #expect(output.contains("20"))
    }

    @Test("Renders checker breakdown table")
    func checkerBreakdown() {
        let summary = makeProjectSummary(
            id: "test",
            passRate: 0.75,
            latestPassed: true,
            checkerRates: ["safety": 1.0, "build": 0.5, "test": 0.75]
        )
        let output = DashboardRenderer.renderProjectDetail(summary, trends: [])
        #expect(output.contains("safety"))
        #expect(output.contains("build"))
        #expect(output.contains("test"))
    }

    @Test("Renders trend sparkline when data available")
    func trendSparkline() {
        let trends = [
            TrendPoint(date: date("2026-05-13"), value: 0.5),
            TrendPoint(date: date("2026-05-14"), value: 0.75),
            TrendPoint(date: date("2026-05-15"), value: 1.0),
        ]
        let summary = makeProjectSummary(id: "test", passRate: 1.0, latestPassed: true)
        let output = DashboardRenderer.renderProjectDetail(summary, trends: trends)
        #expect(output.contains("Trend"))
    }

    @Test("Renders override count")
    func overrideCount() {
        let summary = makeProjectSummary(id: "test", passRate: 1.0, latestPassed: true, overrides: 12)
        let output = DashboardRenderer.renderProjectDetail(summary, trends: [])
        #expect(output.contains("12"))
    }

    // MARK: - JSON Output

    @Test("Renders portfolio as JSON")
    func jsonOutput() throws {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0, latestPassed: true),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        let json = DashboardRenderer.renderJSON(portfolio: portfolio, projects: projects)
        #expect(json.contains("\"totalProjects\""))
        #expect(json.contains("\"alpha\""))
    }
}

// MARK: - Helpers

private func makePortfolio(total: Int, passing: Int, failing: Int) -> PortfolioSummary {
    let projects = (0..<total).map { i in
        makeProjectSummary(
            id: "project-\(i)",
            passRate: i < passing ? 1.0 : 0.0,
            latestPassed: i < passing
        )
    }
    return PortfolioSummary.compute(from: projects)
}

private func makeProjectSummary(
    id: String,
    passRate: Double,
    latestPassed: Bool,
    runCount: Int = 10,
    checkerRates: [String: Double] = ["safety": 1.0],
    overrides: Int = 0
) -> ProjectSummary {
    let passingRunCount = Int((Double(runCount) * passRate).rounded())
    let runs = (0..<runCount).map { i in
        let runPasses: Bool
        if latestPassed {
            runPasses = i >= (runCount - passingRunCount)
        } else {
            runPasses = i < passingRunCount
        }
        let results = checkerRates.map { checkerId, rate in
            let checkerPasses = runPasses || (Double(i) / Double(max(runCount, 1)) < rate)
            return CheckResult(
                checkerId: checkerId,
                status: checkerPasses ? .passed : .failed,
                diagnostics: [],
                duration: .milliseconds(100)
            )
        }
        let finalResults: [CheckResult]
        if !runPasses {
            var modified = results
            modified.append(CheckResult(
                checkerId: "_gate",
                status: .failed,
                diagnostics: [],
                duration: .milliseconds(1)
            ))
            finalResults = modified
        } else {
            finalResults = results
        }
        let overridesForRun = i == 0 ? (0..<overrides).map { _ in
            OverrideRecord(
                diagnosticOverride: DiagnosticOverride(ruleId: "test", justification: "test"),
                author: "test",
                riskTier: .operational,
                authorityLevel: .peer
            )
        } : []
        return TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: id,
                timestamp: Date(timeIntervalSince1970: Double(1747267200 + i * 3600)),
                environment: .local,
                decisionOwner: "test",
                results: finalResults,
                overrides: overridesForRun,
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
        )
    }
    return ProjectSummary.compute(projectID: id, from: runs)
}

private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

private func date(_ str: String) -> Date {
    dateFormatter.date(from: str) ?? Date()
}
