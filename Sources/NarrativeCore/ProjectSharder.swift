import Foundation

/// A per-project prompt shard: the isolated bundle of facts fed to the map step
/// of the on-device narrator. Small enough to fit the 4,096-token window with
/// room to spare (largest observed on the live corpus: ~715 tokens).
public struct ProjectShard: Sendable, Equatable {
    /// The project this shard describes.
    public let projectID: String
    /// The assembled prompt text for the project.
    public let text: String

    /// Creates a shard for one project.
    public init(projectID: String, text: String) {
        self.projectID = projectID
        self.text = text
    }
}

/// Turns one project's isolated ``ProjectFacts`` into a deterministic prompt
/// shard. Pure and side-effect-free: identical input yields byte-identical
/// output, so the map step is reproducible and unit-testable without a model.
public struct ProjectSharder: Sendable {
    /// The maximum number of distinct commit SHAs to include per project. Caps
    /// shard size while preserving the most recent, richest attribution.
    public let maxSHAs: Int
    /// The maximum number of anomalies to include per project, highest |z| first.
    public let maxAnomalies: Int
    /// The maximum characters kept from a single commit-subject line.
    public let maxSubjectChars: Int

    /// Creates a sharder with caps on SHAs, anomalies, and subject length per shard.
    public init(maxSHAs: Int = 3, maxAnomalies: Int = 6, maxSubjectChars: Int = 300) {
        self.maxSHAs = maxSHAs
        self.maxAnomalies = maxAnomalies
        self.maxSubjectChars = maxSubjectChars
    }

    /// Builds shards for every project, sorted by project ID for stable output.
    public func shards(for facts: [ProjectFacts]) -> [ProjectShard] {
        facts.sorted { $0.projectID < $1.projectID }.map(shard(for:))
    }

    /// Builds the shard for a single project.
    public func shard(for facts: ProjectFacts) -> ProjectShard {
        var lines: [String] = ["# Project: \(facts.projectID)"]

        if facts.passing {
            lines.append("Status: PASSING; overrides=\(facts.overrideCount)")
        } else {
            let checkers = facts.failedCheckers.isEmpty ? "unspecified" : facts.failedCheckers.joined(separator: ", ")
            lines.append("Status: FAILING: \(checkers); overrides=\(facts.overrideCount)")
        }

        if let score = facts.weightedScore {
            let tier = facts.tier ?? "-"
            lines.append("Weighted score: \(fmt(score, 3)) (tier \(tier))")
        } else if let tier = facts.tier {
            lines.append("Tier: \(tier)")
        }

        if let t = facts.trajectory {
            var line = "Trajectory: \(t.direction) slope=\(fmt(t.slope, 4)) r2=\(fmt(t.rSquared, 2)) n=\(t.sampleSize)"
            if t.inflectionDetected, let recent = t.recentSlope {
                line += " [inflection recentSlope=\(fmt(recent, 4))]"
            }
            lines.append(line)
        }

        let anomalies = topAnomalies(facts.anomalies)
        if !anomalies.isEmpty {
            lines.append("Anomalies (\(anomalies.count)):")
            for a in anomalies {
                lines.append("  - \(a.metric) \(a.direction) obs=\(fmt(a.observedValue, 3)) exp=\(fmt(a.expectedValue, 3)) z=\(fmt(a.zScore, 2)) [\(a.gatedSeverity)/\(a.actionability)]")
            }
        }

        let work = topWork(facts.work)
        if !work.isEmpty {
            lines.append("Recent work (top \(work.count) by recency):")
            let dayFormatter = Self.makeDayFormatter()
            for w in work {
                let day = dayFormatter.string(from: w.date)
                let sha = w.commitSHA.map { "@\($0)" } ?? "(no-sha)"
                let subjects = w.commitSubjects.joined(separator: "; ")
                let trimmed = subjects.count > maxSubjectChars ? String(subjects.prefix(maxSubjectChars)) : subjects
                lines.append("  - \(day) \(sha): \(trimmed)")
            }
        }

        return ProjectShard(projectID: facts.projectID, text: lines.joined(separator: "\n"))
    }

    // MARK: - Selection (deterministic)

    /// The most recent distinct-SHA work entries, richest-subject wins on a date tie.
    private func topWork(_ work: [WorkFacts]) -> [WorkFacts] {
        let withSHA = work.filter { ($0.commitSHA?.isEmpty == false) }
        let sorted = withSHA.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            if a.commitSubjects.count != b.commitSubjects.count { return a.commitSubjects.count > b.commitSubjects.count }
            return (a.commitSHA ?? "") < (b.commitSHA ?? "")
        }
        var seen: Set<String> = []
        var out: [WorkFacts] = []
        for w in sorted {
            guard let sha = w.commitSHA, !seen.contains(sha) else { continue }
            seen.insert(sha)
            out.append(w)
            if out.count >= maxSHAs { break }
        }
        return out
    }

    /// The highest-magnitude anomalies, metric name breaking ties for stability.
    private func topAnomalies(_ anomalies: [AnomalyFacts]) -> [AnomalyFacts] {
        let sorted = anomalies.sorted { a, b in
            let za = abs(a.zScore)
            let zb = abs(b.zScore)
            if za != zb { return za > zb }
            return a.metric < b.metric
        }
        return Array(sorted.prefix(maxAnomalies))
    }

    // MARK: - Formatting helpers

    private func fmt(_ value: Double, _ places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)).grouping(.never))
    }

    private static func makeDayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }
}
