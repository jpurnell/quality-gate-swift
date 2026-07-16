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
    /// Whether every checker's most recent standard-mode result passes — the
    /// composite gate status shown in the overview. This can be true from a
    /// mix of full and targeted `--check` runs (a small fix re-run flips it
    /// green immediately); consult ``latestFullPassed`` to know whether one
    /// full gate run actually confirmed the whole picture.
    public let latestPassed: Bool
    /// Whether the most recent *full*, standard-mode run passed every checker —
    /// the strong signal that a single gate run confirmed the green. When
    /// ``latestPassed`` is true but this is false, the green was assembled from
    /// partial runs and renders distinctly (✓* vs ✓). Defaulted so the
    /// memberwise initializer stays source-compatible.
    public var latestFullPassed: Bool = false
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

    /// The overview gate verdict, unifying the composite pass state with the
    /// full-run confirmation marker so every surface renders it the same way.
    public enum GateStatus: Sendable, Equatable {
        /// A checker's latest standard result is failing.
        case failing
        /// Every checker passes, but the green was assembled from partial runs —
        /// no single full gate confirmed it. Renders as ✓*.
        case passingPartial
        /// Every checker passes and the latest full standard run confirmed it.
        /// Renders as ✓.
        case passingConfirmed

        /// The status glyph: ✓ (full-confirmed), ✓* (partial-confirmed), ✗.
        public var symbol: String {
            switch self {
            case .failing: return "\u{2717}"
            case .passingPartial: return "\u{2713}*"
            case .passingConfirmed: return "\u{2713}"
            }
        }

        /// Whether this status counts as passing for rollups and filters.
        public var isPassing: Bool { self != .failing }

        /// Rolls a group of member verdicts into one: failing if any member
        /// fails (or the group is empty), fully confirmed only when every member
        /// is confirmed, otherwise partial.
        public static func aggregate<S: Sequence>(_ statuses: S) -> GateStatus
        where S.Element == GateStatus {
            var sawAny = false
            var allConfirmed = true
            for status in statuses {
                sawAny = true
                if status == .failing { return .failing }
                if status != .passingConfirmed { allConfirmed = false }
            }
            guard sawAny else { return .failing }
            return allConfirmed ? .passingConfirmed : .passingPartial
        }
    }

    /// The unified gate verdict for this project (see ``GateStatus``).
    public var gateStatus: GateStatus {
        guard latestPassed else { return .failing }
        return latestFullPassed ? .passingConfirmed : .passingPartial
    }

    /// A short textual verdict for plain-text surfaces: "pass", "pass*"
    /// (partial-confirmed), or "fail".
    public var gateStatusLabel: String {
        switch gateStatus {
        case .failing: return "fail"
        case .passingPartial: return "pass*"
        case .passingConfirmed: return "pass"
        }
    }

    /// Creates a summary directly. The ``compute(projectID:from:lifecycle:orientation:censusDate:)``
    /// factory is the normal path from run data; this initializer lets consumers
    /// (a dashboard UI, SwiftUI previews, tests) build fixtures without run telemetry.
    public init(
        projectID: String,
        passRate: Double,
        latestPassed: Bool,
        latestFullPassed: Bool = false,
        worstChecker: String? = nil,
        checkerPassRates: [String: Double] = [:],
        latestCheckerPassed: [String: Bool] = [:],
        totalOverrides: Int = 0,
        runCount: Int,
        partialRunCount: Int = 0,
        lifecycle: ProjectLifecycle = .active,
        orientation: ModuleOrientationCard? = nil,
        writerCensus: WriterCensus? = nil,
        baselineBurnDown: [BaselineSnapshot] = []
    ) {
        self.projectID = projectID
        self.passRate = passRate
        self.latestPassed = latestPassed
        self.latestFullPassed = latestFullPassed
        self.worstChecker = worstChecker
        self.checkerPassRates = checkerPassRates
        self.latestCheckerPassed = latestCheckerPassed
        self.totalOverrides = totalOverrides
        self.runCount = runCount
        self.partialRunCount = partialRunCount
        self.lifecycle = lifecycle
        self.orientation = orientation
        self.writerCensus = writerCensus
        self.baselineBurnDown = baselineBurnDown
    }

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

        // The strong signal: did the most recent *full* standard run pass every
        // checker at once? This is what the ✓ (vs ✓*) marker confirms.
        let latestFullRun = fullRuns.last
        let latestFullPassed = latestFullRun.map { run in
            run.metadata.results.allSatisfy { $0.status.isPassing }
        } ?? false

        let checkerPassRates = computeCheckerPassRates(across: sortedRuns)
        let worstChecker = checkerPassRates.min { $0.value < $1.value }?.key

        // Composite gate state: each checker's most recent *standard-mode*
        // result (any scope — a targeted `--check` counts). Advisory surveys
        // are excluded — they report, they never confirm a green gate.
        let standardRuns = sortedRuns.filter { $0.metadata.gateMode == .standard }
        let (latestCheckerPassed, latestPassed) = compositeCheckerState(from: standardRuns)

        let totalOverrides = sortedRuns.reduce(0) { $0 + $1.metadata.overrides.count }

        var summary = ProjectSummary(
            projectID: projectID,
            passRate: passRate,
            latestPassed: latestPassed,
            latestFullPassed: latestFullPassed,
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

    /// Per-checker pass rate across every run (all scopes): how often each
    /// checker passed out of the times it ran.
    private static func computeCheckerPassRates(
        across runs: [TimestampedRun]
    ) -> [String: Double] {
        var passCount: [String: Int] = [:]
        var totalCount: [String: Int] = [:]
        for run in runs {
            for result in run.metadata.results {
                totalCount[result.checkerId, default: 0] += 1
                if result.status.isPassing {
                    passCount[result.checkerId, default: 0] += 1
                }
            }
        }
        var rates: [String: Double] = [:]
        for (checkerId, total) in totalCount where total > 0 {
            rates[checkerId] = Double(passCount[checkerId, default: 0]) / Double(total)
        }
        return rates
    }

    /// Each checker's most recent standard-mode pass state, and whether the
    /// composite gate is green (every observed checker passing). `standardRuns`
    /// must already exclude advisory surveys — they never confirm a gate.
    private static func compositeCheckerState(
        from standardRuns: [TimestampedRun]
    ) -> (latestCheckerPassed: [String: Bool], latestPassed: Bool) {
        var latestCheckerPassed: [String: Bool] = [:]
        for run in standardRuns.reversed() {
            for result in run.metadata.results where latestCheckerPassed[result.checkerId] == nil {
                latestCheckerPassed[result.checkerId] = result.status.isPassing
            }
        }
        let latestPassed = !latestCheckerPassed.isEmpty
            && latestCheckerPassed.values.allSatisfy { $0 }
        return (latestCheckerPassed, latestPassed)
    }
}
