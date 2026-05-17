import Testing
import Foundation
@testable import IJSDashboardCLI
@testable import IJSDashboardCore
import IJSSensor
import QualityGateTypes

@Suite("HTMLReportRenderer")
struct HTMLReportRendererTests {

    // MARK: - Structure

    @Test("produces valid HTML document with doctype and closing tags")
    func validHTMLStructure() {
        let portfolio = makePortfolio(total: 2, passing: 1, failing: 1)
        let projects = makeProjects()
        let html = HTMLReportRenderer.render(portfolio: portfolio, projects: projects, pulse: nil)
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<html"))
        #expect(html.contains("</html>"))
        #expect(html.contains("<head>"))
        #expect(html.contains("</head>"))
        #expect(html.contains("<body>"))
        #expect(html.contains("</body>"))
    }

    @Test("includes embedded CSS (self-contained)")
    func selfContainedCSS() {
        let html = HTMLReportRenderer.render(
            portfolio: makePortfolio(total: 1, passing: 1, failing: 0),
            projects: makeProjects(),
            pulse: nil
        )
        #expect(html.contains("<style>"))
        #expect(html.contains("</style>"))
    }

    @Test("includes title with IJS Portfolio")
    func titlePresent() {
        let html = HTMLReportRenderer.render(
            portfolio: makePortfolio(total: 1, passing: 1, failing: 0),
            projects: makeProjects(),
            pulse: nil
        )
        #expect(html.contains("<title>"))
        #expect(html.contains("IJS"))
    }

    // MARK: - Portfolio Section

    @Test("renders project counts in portfolio header")
    func portfolioProjectCounts() {
        let portfolio = makePortfolio(total: 5, passing: 3, failing: 2)
        let html = HTMLReportRenderer.render(portfolio: portfolio, projects: makeProjects(), pulse: nil)
        #expect(html.contains("5"))
        #expect(html.contains("3"))
        #expect(html.contains("2"))
    }

    @Test("renders project table with names and pass rates")
    func projectTable() {
        let projects = [
            makeProjectSummary(id: "alpha-project", passRate: 0.80, latestPassed: true),
            makeProjectSummary(id: "beta-project", passRate: 0.40, latestPassed: false),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        let html = HTMLReportRenderer.render(portfolio: portfolio, projects: projects, pulse: nil)
        #expect(html.contains("alpha-project"))
        #expect(html.contains("beta-project"))
        #expect(html.contains("80%"))
        #expect(html.contains("40%"))
    }

    @Test("renders worst checkers list")
    func worstCheckers() {
        let projects = [
            makeProjectSummary(id: "a", passRate: 0.5, latestPassed: false,
                               checkerRates: ["safety": 0.0, "build": 1.0]),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        let html = HTMLReportRenderer.render(portfolio: portfolio, projects: projects, pulse: nil)
        #expect(html.contains("safety"))
    }

    // MARK: - Pulse Section

    @Test("renders pulse statistics when pulse provided")
    func pulseStatistics() {
        let pulse = makePulse(gateRuns: 200, passedRuns: 120, failedRuns: 80)
        let html = HTMLReportRenderer.render(
            portfolio: makePortfolio(total: 1, passing: 1, failing: 0),
            projects: makeProjects(),
            pulse: pulse
        )
        #expect(html.contains("200"))
        #expect(html.contains("60.0"))
        #expect(html.contains("2026-W20"))
    }

    @Test("renders violation clusters in pulse section")
    func pulseClusters() {
        let pulse = makePulse(clusters: [
            ViolationCluster(ruleId: "force-unwrap", occurrenceCount: 50,
                             affectedProjectCount: 10, dominantRootCause: nil,
                             dominantFailedStep: nil, isRecurring: true),
            ViolationCluster(ruleId: "missing-guard", occurrenceCount: 25,
                             affectedProjectCount: 5, dominantRootCause: nil,
                             dominantFailedStep: nil, isRecurring: false),
        ])
        let html = HTMLReportRenderer.render(
            portfolio: makePortfolio(total: 1, passing: 1, failing: 0),
            projects: makeProjects(),
            pulse: pulse
        )
        #expect(html.contains("force-unwrap"))
        #expect(html.contains("50"))
        #expect(html.contains("missing-guard"))
    }

    @Test("marks recurring clusters")
    func recurringClusterIndicator() {
        let pulse = makePulse(clusters: [
            ViolationCluster(ruleId: "test-rule", occurrenceCount: 10,
                             affectedProjectCount: 3, dominantRootCause: nil,
                             dominantFailedStep: nil, isRecurring: true),
        ])
        let html = HTMLReportRenderer.render(
            portfolio: makePortfolio(total: 1, passing: 1, failing: 0),
            projects: makeProjects(),
            pulse: pulse
        )
        let lowered = html.lowercased()
        #expect(lowered.contains("recurring"))
    }

    @Test("renders anomalies with severity and z-score")
    func pulseAnomalies() {
        let stats = makeStats(anomalies: [
            StatisticalAnomaly(
                metric: "pass_rate", observedValue: 0.4, expectedValue: 0.7,
                zScore: -2.34, severity: .significant, date: Date(),
                scope: "corpus", direction: .negative, baselineValidity: .valid
            ),
        ])
        let pulse = makePulse(stats: stats)
        let html = HTMLReportRenderer.render(
            portfolio: makePortfolio(total: 1, passing: 1, failing: 0),
            projects: makeProjects(),
            pulse: pulse
        )
        #expect(html.contains("pass_rate"))
        #expect(html.contains("2.34"))
        #expect(html.contains("significant"))
    }

    @Test("renders narrative text when present")
    func narrativePresent() {
        let pulse = makePulse(narrative: "This week saw a significant improvement in code quality.")
        let html = HTMLReportRenderer.render(
            portfolio: makePortfolio(total: 1, passing: 1, failing: 0),
            projects: makeProjects(),
            pulse: pulse
        )
        #expect(html.contains("significant improvement"))
    }

    @Test("omits pulse section when pulse is nil")
    func noPulseSection() {
        let html = HTMLReportRenderer.render(
            portfolio: makePortfolio(total: 1, passing: 1, failing: 0),
            projects: makeProjects(),
            pulse: nil
        )
        #expect(!html.contains("<section class=\"pulse\">"))
        #expect(!html.contains("2026-W"))
    }

    // MARK: - No Empty Projects

    @Test("renders gracefully with empty project list")
    func emptyProjects() {
        let portfolio = PortfolioSummary.compute(from: [])
        let html = HTMLReportRenderer.render(portfolio: portfolio, projects: [], pulse: nil)
        #expect(html.contains("0"))
        #expect(html.contains("</html>"))
    }

    // MARK: - HTML Safety

    @Test("escapes HTML special characters in project IDs")
    func htmlEscaping() {
        let projects = [
            makeProjectSummary(id: "<script>alert(1)</script>", passRate: 1.0, latestPassed: true),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        let html = HTMLReportRenderer.render(portfolio: portfolio, projects: projects, pulse: nil)
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test("escapes HTML in narrative text")
    func narrativeEscaping() {
        let pulse = makePulse(narrative: "Rate <50% is <b>dangerous</b>")
        let html = HTMLReportRenderer.render(
            portfolio: makePortfolio(total: 1, passing: 1, failing: 0),
            projects: makeProjects(),
            pulse: pulse
        )
        #expect(!html.contains("<b>dangerous</b>"))
        #expect(html.contains("&lt;b&gt;"))
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

private func makeProjects() -> [ProjectSummary] {
    [makeProjectSummary(id: "test-project", passRate: 0.8, latestPassed: true)]
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

private func makeStats(
    totalGateRuns: Int = 100,
    passedRuns: Int = 60,
    failedRuns: Int = 40,
    overrides: Int = 0,
    calibrations: Int = 0,
    consistencyScore: Double? = nil,
    anomalies: [StatisticalAnomaly] = []
) -> PulseStatistics {
    PulseStatistics(
        totalGateRuns: totalGateRuns,
        passedRuns: passedRuns,
        failedRuns: failedRuns,
        totalOverrides: overrides,
        totalCalibrations: calibrations,
        overridesByRiskTier: [:],
        failuresByChecker: [:],
        rootCauseDistribution: [:],
        failedStepDistribution: [:],
        meanConsistencyScore: consistencyScore,
        corpusTrends: [],
        projectTrends: [:],
        anomalies: anomalies,
        corpusSnapshots: [],
        projectSnapshots: [:]
    )
}

private func makePulse(
    gateRuns: Int = 100,
    passedRuns: Int = 60,
    failedRuns: Int = 40,
    clusters: [ViolationCluster] = [],
    narrative: String? = nil,
    stats: PulseStatistics? = nil
) -> InstitutionalPulse {
    let effectiveStats = stats ?? makeStats(
        totalGateRuns: gateRuns,
        passedRuns: passedRuns,
        failedRuns: failedRuns
    )
    return InstitutionalPulse(
        windowStart: Date(timeIntervalSince1970: 1747267200),
        windowEnd: Date(timeIntervalSince1970: 1747872000),
        weekLabel: "2026-W20",
        projects: ["test-project"],
        statistics: effectiveStats,
        violationClusters: clusters,
        proposedPolicyUpdates: [],
        calibrationSummaries: [],
        narrative: narrative,
        generatedAt: Date()
    )
}
