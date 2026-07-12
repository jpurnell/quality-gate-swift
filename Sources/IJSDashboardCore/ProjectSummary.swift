import Foundation
import IJSAggregator
import IJSSensor
import QualityGateTypes

/// Aggregated statistics for a single project's quality gate history.
public struct ProjectSummary: Sendable {
    /// The project identifier.
    public let projectID: String
    /// Fraction of runs where all checkers passed (0.0–1.0).
    public let passRate: Double
    /// Whether the most recent run passed all checkers.
    public let latestPassed: Bool
    /// The checker with the lowest pass rate, if any.
    public let worstChecker: String?
    /// Per-checker pass rates across all runs.
    public let checkerPassRates: [String: Double]
    /// Whether each checker passed in the most recent run.
    public let latestCheckerPassed: [String: Bool]
    /// Total number of overrides across all runs.
    public let totalOverrides: Int
    /// Number of full gate runs analyzed. Pass rate and latest status are
    /// computed over these only — a green subset run is not a green gate.
    public let runCount: Int
    /// Number of subset (`--check <subset>`) runs. Shown as "(+M partial)";
    /// they inform per-checker rates but never the gate pass rate. Defaulted
    /// so the memberwise initializer stays source-compatible.
    public var partialRunCount: Int = 0
    /// The lifecycle state of the project.
    public let lifecycle: ProjectLifecycle
    /// Product-composition orientation (built-from / relied-on-by / role), if a
    /// cross-package orientation report is available for this project. Defaulted so
    /// the memberwise initializer stays source-compatible with existing callers.
    public var orientation: ModuleOrientationCard? = nil
    /// Second-writer tripwire result over the loaded runs (Phase 2 §4b).
    /// Defaulted for memberwise source-compatibility.
    public var writerCensus: WriterCensus? = nil
    /// Baseline-ledger counts from every run that applied one, oldest first —
    /// the debt burn-down series (Phase 4c §3). Empty when no run had a
    /// ledger. Defaulted for memberwise source-compatibility.
    public var baselineBurnDown: [BaselineSnapshot] = []

    /// The most recent run's baseline counts, when a ledger is in play.
    public var latestBaseline: BaselineSnapshot? { baselineBurnDown.last }

    /// Computes a summary from a series of timestamped runs.
    ///
    /// - Parameters:
    ///   - projectID: The project identifier.
    ///   - runs: The timestamped runs to analyze.
    ///   - lifecycle: The project's lifecycle state (defaults to ``ProjectLifecycle/active``).
    /// - Returns: An aggregated summary of the project's quality gate history.
    public static func compute(
        projectID: String,
        from runs: [TimestampedRun],
        lifecycle: ProjectLifecycle = .active,
        orientation: ModuleOrientationCard? = nil,
        censusDate: Date = Date()
    ) -> ProjectSummary {
        guard !runs.isEmpty else {
            return ProjectSummary(
                projectID: projectID,
                passRate: 0,
                latestPassed: false,
                worstChecker: nil,
                checkerPassRates: [:],
                latestCheckerPassed: [:],
                totalOverrides: 0,
                runCount: 0,
                lifecycle: lifecycle,
                orientation: orientation
            )
        }

        let sortedRuns = runs.sorted { $0.metadata.timestamp < $1.metadata.timestamp }

        // Gate-level statistics count full, standard-mode runs only: a green
        // subset run is not a green gate (0.1), and an advisory survey is not
        // a gate at all (Phase 4 §3).
        let fullRuns = sortedRuns.filter {
            $0.metadata.runScope == .full && $0.metadata.gateMode == .standard
        }
        let passingCount = fullRuns.filter { run in
            run.metadata.results.allSatisfy { $0.status.isPassing }
        }.count
        let runTotal = Double(fullRuns.count)
        let passRate = runTotal > 0 ? Double(passingCount) / runTotal : 0

        let latestRun = fullRuns.last
        let latestPassed = latestRun.map { run in
            run.metadata.results.allSatisfy { $0.status.isPassing }
        } ?? false

        var checkerPassCount: [String: Int] = [:]
        var checkerTotalCount: [String: Int] = [:]
        for run in sortedRuns {
            for result in run.metadata.results {
                checkerTotalCount[result.checkerId, default: 0] += 1
                if result.status.isPassing {
                    checkerPassCount[result.checkerId, default: 0] += 1
                }
            }
        }

        var checkerPassRates: [String: Double] = [:]
        for (checkerId, total) in checkerTotalCount {
            guard total > 0 else { continue }
            checkerPassRates[checkerId] = Double(checkerPassCount[checkerId, default: 0]) / Double(total)
        }

        let worstChecker = checkerPassRates.min { $0.value < $1.value }?.key

        var latestCheckerPassed: [String: Bool] = [:]
        for run in sortedRuns.reversed() {
            for result in run.metadata.results {
                if latestCheckerPassed[result.checkerId] == nil {
                    latestCheckerPassed[result.checkerId] = result.status.isPassing
                }
            }
        }

        let totalOverrides = sortedRuns.reduce(0) { $0 + $1.metadata.overrides.count }

        var summary = ProjectSummary(
            projectID: projectID,
            passRate: passRate,
            latestPassed: latestPassed,
            worstChecker: worstChecker,
            checkerPassRates: checkerPassRates,
            latestCheckerPassed: latestCheckerPassed,
            totalOverrides: totalOverrides,
            runCount: fullRuns.count,
            lifecycle: lifecycle,
            orientation: orientation
        )
        summary.partialRunCount = sortedRuns.count - fullRuns.count
        // Second-writer tripwire (Phase 2 §4b): all loaded runs feed the
        // census; the standing warning renders until Phase 3 controls exist.
        summary.writerCensus = WriterCensus.census(
            of: sortedRuns.map(\.metadata), now: censusDate)
        // Decaying baseline (Phase 4c §3): every ledgered run feeds the
        // burn-down series — debts trend to zero or expire loudly.
        summary.baselineBurnDown = sortedRuns.compactMap(\.metadata.baseline)
        return summary
    }
}
