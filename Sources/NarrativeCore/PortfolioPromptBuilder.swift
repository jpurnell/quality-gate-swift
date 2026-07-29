import Foundation
import CorpusKit

/// Builds the single monolithic system + user prompt for the cloud (Claude)
/// narrator. Ported verbatim from the original `GenerateNarrative` so the
/// primary engine's behavior is unchanged; the on-device engine uses a different
/// (sharded) prompt strategy because the whole-pulse prompt is ~69.5k tokens.
public struct PortfolioPromptBuilder: Sendable {
    /// Creates the prompt builder.
    public init() {}

    private func decimal(_ value: Double, _ places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }

    /// The analyst-persona system prompt (audience, structure, style, scoring context).
    public func systemPrompt() -> String {
        """
        You are an institutional quality analyst generating a daily pulse narrative \
        for a Swift development portfolio of ~50 projects. The portfolio owner is a \
        senior developer who manages all these projects personally.

        Your narrative should:
        - Open with a 1–2 sentence summary of the CURRENT STATE from the Current Snapshot section
        - Clearly distinguish between current state (snapshot) and historical trends (window). \
        The reader cares most about "where are we now" and then "how did we get here."
        - Analyze patterns rather than restating numbers the reader can already see in the dashboard
        - Cross-reference related projects (e.g. a parent app and its library dependencies)
        - Distinguish real signals from statistical noise — always note sample sizes
        - Be honest about what the data doesn't support (e.g. "insufficient" trajectories)
        - End with 3–5 forward guidance items ordered by priority and actionability

        Work attribution (only when the user prompt includes a "Recent Work" section):
        - That section lists, per project, the commits and notes behind this window's changes — the causal record.
        - Attribute a metric movement (a trajectory inflection, a resolved anomaly, an override drop) to a work-event ONLY when their dates — and commit SHAs where present — align.
        - Phrase aligned cases as "coincides with" or "following", NOT "caused by", unless a session summary explicitly claims the fix.
        - If no work-event aligns with a movement, stay descriptive. Never invent a cause; unattributed change is fine to report as unattributed.

        Style rules:
        - Use markdown with ## headers and | tables where helpful
        - Be direct and analytical, not promotional
        - Numbers need context: "0.983" means nothing without "up from 0.972" or "highest in portfolio"
        - When a metric rests on few data points, say so explicitly
        - Total length: 800–1200 words
        - Do NOT include YAML frontmatter — it is added by the caller
        - Do NOT open with "# " (h1) — use "## " (h2) for the top heading

        Scoring context:
        - Weighted quality scores range 0.0–1.0; safety/correctness checkers carry higher weight \
        than documentation/style checkers
        - Trajectories use OLS regression on daily weighted scores; r² indicates fit quality
        - "Insufficient" trajectory = fewer than 3 deduplicated full-suite runs — no trend computable
        - Anomalies are gated by statistical maturity: "confirmed" (baseline n≥30), \
        "directional" (15≤n<30), "unreliable" (n<15)
        - Partial debug runs (single-checker invocations) and same-day duplicates are already \
        filtered out before scoring
        """
    }

    /// Assembles the whole-pulse user prompt (snapshot, window stats, scores,
    /// trajectories, anomalies, group summaries, and the recent-work causal record).
    public func userPrompt(
        pulse: InstitutionalPulse,
        previousPulse: InstitutionalPulse?,
        workLogsByProject: [String: [WorkEvent]]
    ) -> String {
        let recentWorkSection = WorkLogFormatter.recentWorkSection(
            workLogsByProject: workLogsByProject,
            windowStart: pulse.windowStart,
            windowEnd: pulse.windowEnd
        )

        let label = pulse.label ?? pulse.weekLabel
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = TimeZone(identifier: "UTC")
        dateFmt.locale = Locale(identifier: "en_US_POSIX")

        var sections: [String] = []

        sections.append("""
            ## Pulse Data: \(label)
            Window: \(dateFmt.string(from: pulse.windowStart)) to \(dateFmt.string(from: pulse.windowEnd))
            Projects in corpus: \(pulse.projects.count)
            Generated: \(dateFmt.string(from: pulse.generatedAt))
            """)

        if let snap = pulse.currentSnapshot {
            let failing = snap.projects.filter { !$0.allPassed }
            var section = """
                ## Current Snapshot (latest run per project)
                This is the CURRENT state — not historical. Use this to answer "how are things right now?"
                - Projects: \(snap.totalProjects) total, \(snap.passingProjects) passing, \(snap.failingProjects) failing
                - Overrides: \(snap.totalOverrides)
                - Compliance annotations: \(snap.totalComplianceCount)
                """
            if failing.isEmpty {
                section += "\n- All projects are currently passing all checkers."
            } else {
                section += "\n- Currently failing projects:"
                for p in failing.sorted(by: { $0.projectID < $1.projectID }) {
                    section += "\n  - \(p.projectID): \(p.failedCheckers.joined(separator: ", "))"
                }
            }
            if !snap.failingCheckers.isEmpty {
                let top = snap.failingCheckers.sorted { $0.value > $1.value }.prefix(5)
                section += "\n- Top failing checkers (current): \(top.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))"
            }
            sections.append(section)
        }

        let s = pulse.statistics
        var stats = """
            ## Window Statistics (30-day aggregate)
            These numbers include ALL runs in the window, including resolved incidents. Do NOT present these as current state.
            - Gate runs: \(s.totalGateRuns)
            - Passed: \(s.passedRuns) (\(decimal(s.passRate, 1))%)
            - Failed: \(s.failedRuns)
            - Overrides: \(s.totalOverrides)
            - Calibrations: \(s.totalCalibrations)
            """
        if let prev = previousPulse {
            let ps = prev.statistics
            stats += "\n\nPrevious pulse (\(prev.label ?? prev.weekLabel)):"
            stats += "\n- Gate runs: \(ps.totalGateRuns) → \(s.totalGateRuns)"
            stats += "\n- Pass rate: \(decimal(ps.passRate, 1))% → \(decimal(s.passRate, 1))%"
            stats += "\n- Overrides: \(ps.totalOverrides) → \(s.totalOverrides)"
        }
        sections.append(stats)

        if let tiers = pulse.projectTiers {
            let grouped = Dictionary(grouping: tiers, by: { $0.value })
            var section = "## Project Tier Distribution"
            for tier in [ProjectTier.active, .baseline, .firstContact, .atRisk, .dormant] {
                let names = (grouped[tier] ?? []).map(\.key).sorted()
                section += "\n- \(tier.rawValue) (\(names.count)): \(names.joined(separator: ", "))"
            }
            sections.append(section)
        }

        if let scores = s.weightedScores {
            let sorted = scores.sorted { $0.value > $1.value }
            var section = "## Weighted Quality Scores\n| Project | Score | Tier |\n|---------|-------|------|"
            for (project, score) in sorted {
                let tier = pulse.projectTiers?[project]?.rawValue ?? "–"
                section += "\n| \(project) | \(decimal(score, 3)) | \(tier) |"
            }

            let vals = sorted.map(\.value)
            let count = vals.count
            if count > 0 { // fp-safety: guarded by count check
                let mean = vals.reduce(0, +) / Double(count)
                let median: Double
                if count % 2 == 0 {
                    let mid = count / 2
                    median = (vals[mid - 1] + vals[mid]) / 2.0
                } else {
                    median = vals[count / 2]
                }
                section += "\n\nMean: \(decimal(mean, 3)), Median: \(decimal(median, 3)), Scored projects: \(count)"
            }

            if let prevScores = previousPulse?.statistics.weightedScores {
                let prevVals = Array(prevScores.values)
                let currVals = Array(scores.values)
                if !prevVals.isEmpty && !currVals.isEmpty { // fp-safety: guarded
                    let prevMean = prevVals.reduce(0, +) / Double(prevVals.count)
                    let currMean = currVals.reduce(0, +) / Double(currVals.count)
                    section += "\nPrevious mean: \(decimal(prevMean, 3)) → Current: \(decimal(currMean, 3))"
                }
            }
            sections.append(section)
        }

        if let trajectories = pulse.projectTrajectories {
            let byDir = Dictionary(grouping: trajectories, by: { $0.direction })
            var section = "## Trajectories"

            for dir in [TrajectoryDirection.improving, .stable, .declining] {
                let projs = byDir[dir] ?? []
                if projs.isEmpty { continue }
                section += "\n\n### \(dir.rawValue.capitalized) (\(projs.count))"
                for t in projs.sorted(by: { $0.projectID < $1.projectID }) {
                    section += "\n- \(t.projectID): slope=\(decimal(t.slope, 4)), "
                    section += "r²=\(decimal(t.rSquared, 2)), n=\(t.sampleSize)"
                    if t.inflectionDetected, let recent = t.recentSlope {
                        section += " [inflection, recent slope=\(decimal(recent, 4))]"
                    }
                }
            }

            let insufficient = byDir[.insufficient] ?? []
            if !insufficient.isEmpty {
                section += "\n\nInsufficient data (\(insufficient.count)): "
                section += insufficient.map(\.projectID).sorted().joined(separator: ", ")
            }
            sections.append(section)
        }

        if !s.failuresByChecker.isEmpty {
            let top = s.failuresByChecker.sorted { $0.value > $1.value }.prefix(10)
            var section = "## Top Failing Checkers"
            for (checker, count) in top {
                section += "\n- \(checker): \(count)"
            }
            sections.append(section)
        }

        if let gated = s.gatedAnomalies, !gated.isEmpty {
            var section = "## Gated Anomalies (\(gated.count))"
            for g in gated {
                let a = g.anomaly
                section += "\n- [\(g.gatedSeverity.rawValue)/\(g.actionability.rawValue)] "
                section += "\(a.metric) in \(a.scope): "
                section += "observed=\(decimal(a.observedValue, 3)), "
                section += "expected=\(decimal(a.expectedValue, 3)), "
                section += "z=\(decimal(a.zScore, 2)), "
                section += "baseline=\(a.baselineValidity.rawValue)"
            }
            sections.append(section)
        } else if !s.anomalies.isEmpty {
            var section = "## Anomalies (\(s.anomalies.count))"
            for a in s.anomalies {
                section += "\n- \(a.metric) in \(a.scope): z=\(decimal(a.zScore, 2)), "
                section += "\(a.direction.rawValue), baseline=\(a.baselineValidity.rawValue)"
            }
            sections.append(section)
        }

        if let groups = pulse.groupSnapshots, !groups.isEmpty {
            var section = "## Group Summaries"
            for (groupID, snaps) in groups.sorted(by: { $0.key < $1.key }) {
                let runs = snaps.reduce(0) { $0 + $1.gateRuns }
                let passed = snaps.reduce(0) { $0 + $1.passedRuns }
                let failed = snaps.reduce(0) { $0 + $1.failedRuns }
                section += "\n- \(groupID): \(runs) runs (\(passed) passed, \(failed) failed), "
                section += "\(snaps.count) active days"
            }
            sections.append(section)
        }

        if let recentWorkSection {
            sections.append(recentWorkSection)
        }

        return sections.joined(separator: "\n\n")
    }
}
