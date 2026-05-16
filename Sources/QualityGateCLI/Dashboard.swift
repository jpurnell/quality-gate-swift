import ArgumentParser // logging: CLI tool — print() is appropriate for user-facing output
import Foundation
import QualityGateCore
import IJSSensor
import IJSAggregator
import IJSDashboardCore
import IJSDashboardCLI

struct Dashboard: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "dashboard",
        abstract: "View quality gate trends and project health."
    )

    @Option(name: .long, help: "Path to the IJS corpus directory (overrides .quality-gate.yml)")
    var corpusPath: String?

    @Option(name: .long, help: "Show detail for a specific project")
    var project: String?

    @Option(name: .long, help: "Output format (terminal, json)")
    var outputFormat: String = "terminal"

    @Flag(name: .long, help: "Show one-shot portfolio summary (non-interactive)")
    var summary: Bool = false

    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    func run() async throws {
        var configuration: Configuration
        do {
            configuration = try Configuration.load(from: config)
        } catch { // logging: falling back to default configuration
            configuration = Configuration()
        }

        let effectiveCorpusPath = corpusPath ?? configuration.consistency.corpusPath
        guard let effectiveCorpusPath else {
            print("[dashboard] Error: No corpus path configured.") // logging: CLI user-facing output
            print("[dashboard] Set consistency.corpusPath in .quality-gate.yml or use --corpus-path.") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        let reader = CorpusReader(corpusPath: effectiveCorpusPath)
        let allRuns: [String: [TimestampedRun]]
        do {
            allRuns = try reader.loadAll()
        } catch {
            print("[dashboard] Error: Failed to read corpus: \(error.localizedDescription)") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        if let projectID = project {
            let runs = allRuns[projectID] ?? []
            guard !runs.isEmpty else {
                print("[dashboard] No data found for project: \(projectID)") // logging: CLI user-facing output
                throw ExitCode(1)
            }
            let projectSummary = ProjectSummary.compute(projectID: projectID, from: runs)
            let trends = TrendComputer.dailyPassRate(from: runs)

            if outputFormat == "json" {
                let portfolio = PortfolioSummary.compute(from: [projectSummary])
                print(DashboardRenderer.renderJSON(portfolio: portfolio, projects: [projectSummary])) // logging: CLI user-facing output
            } else {
                print(DashboardRenderer.renderProjectDetail(projectSummary, trends: trends)) // logging: CLI user-facing output
            }
            return
        }

        let projects = allRuns.map { (projectID, runs) in
            ProjectSummary.compute(projectID: projectID, from: runs)
        }.sorted { $0.projectID < $1.projectID }

        let portfolio = PortfolioSummary.compute(from: projects)

        if outputFormat == "json" {
            print(DashboardRenderer.renderJSON(portfolio: portfolio, projects: projects)) // logging: CLI user-facing output
        } else if summary {
            print(DashboardRenderer.renderPortfolio(portfolio, projects: projects)) // logging: CLI user-facing output
        } else {
            DashboardApp.run(portfolio: portfolio, projects: projects, allRuns: allRuns)
        }
    }
}
