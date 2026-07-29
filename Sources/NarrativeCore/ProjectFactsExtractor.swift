import Foundation
import CorpusKit

/// Derives per-project ``ProjectFacts`` from a whole-pulse ``NarrativeInput``.
///
/// This is where cross-project isolation is enforced: each project's facts carry
/// only its own snapshot status, score, trajectory, anomalies (matched on
/// `scope`), and work-log — nothing from any sibling. Downstream, ``ProjectSharder``
/// only formats what it is handed, so contamination cannot be introduced later.
public struct ProjectFactsExtractor: Sendable {
    /// Creates the extractor.
    public init() {}

    /// Extracts facts for every project the pulse knows about, sorted by ID.
    public func facts(from input: NarrativeInput) -> [ProjectFacts] {
        let pulse = input.pulse

        // Index the pieces once for O(1) per-project lookup.
        let statusByID: [String: CurrentSnapshot.ProjectStatus] = Dictionary(
            (pulse.currentSnapshot?.projects ?? []).map { ($0.projectID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let trajectoryByID: [String: ProjectTrajectory] = Dictionary(
            (pulse.projectTrajectories ?? []).map { ($0.projectID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var anomaliesByID: [String: [AnomalyFacts]] = [:]
        for gate in pulse.statistics.gatedAnomalies ?? [] {
            let a = gate.anomaly
            let facts = AnomalyFacts(
                metric: a.metric,
                direction: a.direction.rawValue,
                observedValue: a.observedValue,
                expectedValue: a.expectedValue,
                zScore: a.zScore,
                gatedSeverity: gate.gatedSeverity.rawValue,
                actionability: gate.actionability.rawValue
            )
            anomaliesByID[a.scope, default: []].append(facts)
        }

        let scores = pulse.statistics.weightedScores ?? [:]
        let tiers = pulse.projectTiers ?? [:]

        // The project universe: everything any surface mentions.
        var ids: Set<String> = []
        ids.formUnion(statusByID.keys)
        ids.formUnion(trajectoryByID.keys)
        ids.formUnion(scores.keys)
        ids.formUnion(input.workLogsByProject.keys)
        ids.formUnion(pulse.projects)

        return ids.sorted().map { id in
            let status = statusByID[id]
            let trajectory = trajectoryByID[id].map {
                TrajectoryFacts(
                    direction: $0.direction.rawValue,
                    slope: $0.slope,
                    rSquared: $0.rSquared,
                    sampleSize: $0.sampleSize,
                    inflectionDetected: $0.inflectionDetected,
                    recentSlope: $0.recentSlope
                )
            }
            let work = (input.workLogsByProject[id] ?? []).map {
                WorkFacts(date: $0.date, commitSHA: $0.commitSHA, commitSubjects: $0.commitSubjects)
            }
            return ProjectFacts(
                projectID: id,
                passing: status?.allPassed ?? true,
                failedCheckers: status?.failedCheckers ?? [],
                overrideCount: status?.overrideCount ?? 0,
                weightedScore: scores[id],
                tier: tiers[id]?.rawValue,
                trajectory: trajectory,
                anomalies: anomaliesByID[id] ?? [],
                work: work
            )
        }
    }
}
