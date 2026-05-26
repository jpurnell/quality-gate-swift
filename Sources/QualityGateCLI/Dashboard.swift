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

    @Flag(name: .long, help: "Export HTML report to pulse directory")
    var exportHtml: Bool = false

    @Option(name: .long, help: "Output path for HTML report (default: pulse directory)")
    var output: String?

    @Option(name: .long, help: "ISO week label to display (e.g. 2026-W20). Defaults to latest.")
    var week: String?

    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    private func syncCorpusFromRemote(at corpusPath: String) {
        let gitDir = "\(corpusPath)/.git"
        guard FileManager.default.fileExists(atPath: gitDir) else { return } // SAFETY: read-only existence check on configured path

        func git(_ arguments: [String]) throws -> ProcessRunner.Output {
            try ProcessRunner.run(
                "/usr/bin/git", // SAFETY: hardcoded system path
                arguments: arguments,
                currentDirectory: corpusPath
            )
        }

        do {
            let fm = FileManager.default
            let rebaseMerge = "\(gitDir)/rebase-merge"
            let rebaseApply = "\(gitDir)/rebase-apply"
            // SAFETY: paths derived from configured corpus gitDir — no user-controlled traversal
            if fm.fileExists(atPath: rebaseMerge) || fm.fileExists(atPath: rebaseApply) {
                print("[dashboard] Recovering from interrupted rebase…") // logging: CLI user-facing output
                let cont = try git(["rebase", "--continue"])
                if cont.exitCode != 0 {
                    _ = try git(["rebase", "--abort"])
                    print("[dashboard] Rebase recovery failed — aborted rebase, retrying pull") // logging: CLI user-facing output
                }
            }

            let status = try git(["status", "--porcelain"])
            if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try git(["add", "-A"])
                let dateStr = ISO8601DateFormatter().string(from: Date())
                _ = try git(["commit", "-m", "telemetry: auto-commit \(dateStr)"])
            }

            let pull = try git(["pull", "--rebase", "--quiet"])
            if pull.exitCode != 0 {
                print("[dashboard] Warning: corpus pull failed (exit \(pull.exitCode)) — using local data") // logging: CLI user-facing output
                return
            }

            let push = try git(["push", "--quiet"])
            if push.exitCode != 0 {
                print("[dashboard] Warning: corpus push failed (exit \(push.exitCode)) — local commit preserved") // logging: CLI user-facing output
            }
        } catch { // logging: non-fatal sync failure — fall back to local corpus data
            print("[dashboard] Warning: corpus sync failed (\(error.localizedDescription)) — using local data") // logging: CLI user-facing output
        }
    }

    private func isoWeekLabel(for date: Date) -> String {
        let calendar = Calendar(identifier: .iso8601)
        let year = calendar.component(.yearForWeekOfYear, from: date)
        let week = calendar.component(.weekOfYear, from: date)
        let yearStr = "\(year)".padding(toLength: 4, withPad: "0", startingAt: 0)
        let weekStr = "\(week)".count < 2 ? "0\(week)" : "\(week)"
        return "\(yearStr)-W\(weekStr)"
    }

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

        syncCorpusFromRemote(at: effectiveCorpusPath)

        let reader = CorpusReader(corpusPath: effectiveCorpusPath)
        let allRuns: [String: [TimestampedRun]]
        do {
            allRuns = try reader.loadAll()
        } catch {
            print("[dashboard] Error: Failed to read corpus: \(error.localizedDescription)") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        let manifest: CorpusManifest
        do {
            manifest = try reader.loadManifest()
        } catch { // logging: manifest is optional; missing file treated as all-active
            manifest = CorpusManifest()
        }

        if let projectID = project {
            let runs = allRuns[projectID] ?? []
            guard !runs.isEmpty else {
                print("[dashboard] No data found for project: \(projectID)") // logging: CLI user-facing output
                throw ExitCode(1)
            }
            let lifecycle = manifest.lifecycle(for: projectID)
            let projectSummary = ProjectSummary.compute(projectID: projectID, from: runs, lifecycle: lifecycle)
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
            let lifecycle = manifest.lifecycle(for: projectID)
            return ProjectSummary.compute(projectID: projectID, from: runs, lifecycle: lifecycle)
        }.sorted { $0.projectID < $1.projectID }

        let portfolio = PortfolioSummary.compute(from: projects)

        let pulse: InstitutionalPulse?
        if let week {
            pulse = reader.loadPulse(weekLabel: week)
        } else {
            pulse = reader.loadLatestPulse()
        }
        let sunsetIDs = projects.filter { $0.lifecycle == .sunset }.map(\.projectID)

        if exportHtml {
            let html = HTMLReportRenderer.render(portfolio: portfolio, projects: projects, pulse: pulse, sunsetProjectIDs: sunsetIDs)
            let outputPath: String
            if let output {
                outputPath = output
            } else {
                let weekLabel = pulse?.weekLabel ?? isoWeekLabel(for: Date())
                let pulseDir = "\(effectiveCorpusPath)/pulse/\(weekLabel)" // SAFETY: corpusPath from config; weekLabel computed from date
                let fm = FileManager.default
                if !fm.fileExists(atPath: pulseDir) { // SAFETY: pulseDir constructed from config corpus path + date-derived week label
                    try fm.createDirectory(atPath: pulseDir, withIntermediateDirectories: true) // SAFETY: creates subdirectory within configured corpus
                }
                outputPath = "\(pulseDir)/REPORT_\(weekLabel).html" // SAFETY: child of configured corpus path
            }
            try Data(html.utf8).write(to: URL(fileURLWithPath: outputPath)) // SAFETY: writes to configured corpus or user-specified path
            print("[dashboard] HTML report written to \(outputPath)") // logging: CLI user-facing output
            return
        }

        if outputFormat == "json" {
            print(DashboardRenderer.renderJSON(portfolio: portfolio, projects: projects)) // logging: CLI user-facing output
        } else if summary {
            print(DashboardRenderer.renderPortfolio(portfolio, projects: projects, pulse: pulse)) // logging: CLI user-facing output
        } else {
            DashboardApp.run(portfolio: portfolio, projects: projects, allRuns: allRuns, corpusReader: reader, pulse: pulse, initialWeek: week)
        }
    }
}
