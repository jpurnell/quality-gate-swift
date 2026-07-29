import Foundation
import CorpusKit
#if canImport(os)
import os
#endif

/// The on-device fallback: a map-reduce over per-project shards, small enough to
/// fit the 4,096-token window. The map step also yields a reusable per-project
/// narrative for every project — persisted as a first-class document, not just an
/// input to the reduce.
///
/// The orchestration here is model-agnostic and fully testable via a mock
/// ``OnDeviceNarrativeGenerator``; the real Foundation Models backing lives in
/// ``SystemLanguageModelGenerator`` and is compiled out where the framework is
/// unavailable.
public struct FoundationModelsNarrativeProvider: NarrativeProvider {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.quality-gate", category: "FoundationModelsNarrative")
    #endif

    /// The source tag recorded for this provider (`onDeviceLLM`).
    public var source: ProseSource { .onDeviceLLM }

    private let generator: any OnDeviceNarrativeGenerator
    private let extractor: ProjectFactsExtractor
    private let sharder: ProjectSharder

    /// Creates the on-device provider from a generator, extractor, and sharder.
    public init(
        generator: any OnDeviceNarrativeGenerator,
        extractor: ProjectFactsExtractor = ProjectFactsExtractor(),
        sharder: ProjectSharder = ProjectSharder()
    ) {
        self.generator = generator
        self.extractor = extractor
        self.sharder = sharder
    }

    /// Available when the underlying on-device generator is ready.
    public func isAvailable(for input: NarrativeInput) -> Bool {
        generator.isAvailable
    }

    /// The map step: one narrative per project, in project-ID order. Reusable
    /// across reduce targets and persisted per-project as a rule. Resilient — a
    /// single project's model error falls back to a deterministic one-liner from
    /// its facts rather than failing the whole run.
    public func mapProjects(_ input: NarrativeInput) async throws -> [ProjectNarrative] {
        let facts = extractor.facts(from: input)
        var narratives: [ProjectNarrative] = []
        narratives.reserveCapacity(facts.count)
        for f in facts {
            let shard = sharder.shard(for: f)
            let text: String
            do {
                let raw = try await generator.generate(instructions: Self.leafInstructions, prompt: shard.text)
                let clean = Self.sanitize(raw)
                // The small model sometimes emits only hallucinated tool-call
                // syntax; when nothing real survives, fall back to the facts.
                text = clean.isEmpty ? Self.fallbackLeaf(f) : clean
            } catch {
                #if canImport(os)
                Self.logger.warning("On-device leaf failed for \(f.projectID, privacy: .public); using deterministic fallback: \(error.localizedDescription, privacy: .public)")
                #endif
                text = Self.fallbackLeaf(f)
            }
            narratives.append(ProjectNarrative(projectID: f.projectID, text: text))
        }
        return narratives
    }

    /// The reduce step: portfolio aggregates + a deterministic, compact status
    /// line per project → the portfolio narrative, in one model call.
    ///
    /// The reduce is fed *deterministic* fact-lines from the extractor rather than
    /// the map step's model prose: this guarantees every project has a clean
    /// PASS/score entry (no "status not available" gaps from a truncated leaf),
    /// keeps the prompt reliably inside the 4,096-token window, and means the
    /// portfolio narrative needs no map pass at all — the map runs only to produce
    /// the persisted per-project documents.
    public func reduce(_ input: NarrativeInput) async throws -> String {
        let raw = try await generator.generate(instructions: Self.reduceInstructions, prompt: portfolioPrompt(input))
        return Self.sanitize(raw)
    }

    /// Strips hallucinated tool-call lines and leading preamble the small model
    /// occasionally emits (e.g. `tool_call: {name: ...}`), keeping only the real
    /// narrative. A line that is, or begins with, a tool-call artifact is dropped
    /// wholesale — this also handles the single-line "call | call | call" form.
    static func sanitize(_ raw: String) -> String {
        func isArtifact(_ trimmed: String) -> Bool {
            let l = trimmed.lowercased()
            return l.hasPrefix("tool call") || l.hasPrefix("tool_call")
                || l.hasPrefix("```tool") || l.contains("{tool_name") || l.contains("\"tool_name\"")
        }
        let kept = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !isArtifact($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "\n")
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the reduce prompt: aggregates + one deterministic line per project.
    func portfolioPrompt(_ input: NarrativeInput) -> String {
        let facts = extractor.facts(from: input)
        let aggregates = Self.aggregateSummary(input.pulse)
        let lines = facts.map { "- \($0.projectID): \(Self.reduceLine($0))" }.joined(separator: "\n")
        return "## Portfolio Aggregates\n\(aggregates)\n\n## Per-project status (\(facts.count))\n\(lines)"
    }

    /// A deterministic, compact status line for the reduce — always includes
    /// PASS/FAIL and score, plus a non-stable trajectory and top anomaly when
    /// present. Bounded so ~50 lines stay well inside the context window.
    static func reduceLine(_ f: ProjectFacts, maxChars: Int = 72) -> String {
        var parts: [String] = [f.passing ? "PASS" : "FAIL(\(f.failedCheckers.prefix(2).joined(separator: ",")))"]
        if let score = f.weightedScore { parts.append("score=\(fmt(score))") }
        if let t = f.trajectory, t.direction != "stable" {
            parts.append("\(t.direction) slope=\(t.slope.formatted(.number.precision(.fractionLength(4)).grouping(.never)))")
        }
        if let top = f.anomalies.max(by: { abs($0.zScore) < abs($1.zScore) }) {
            parts.append("anom \(top.metric) z=\(top.zScore.formatted(.number.precision(.fractionLength(1)).grouping(.never)))")
        }
        let line = parts.joined(separator: " ")
        guard line.count > maxChars else { return line }
        return String(line.prefix(maxChars)).trimmingCharacters(in: .whitespaces)
    }

    /// A deterministic, fact-only one-liner used when the model can't produce a leaf.
    static func fallbackLeaf(_ f: ProjectFacts) -> String {
        var parts: [String] = [f.passing ? "passing" : "failing (\(f.failedCheckers.joined(separator: ", ")))"]
        if let score = f.weightedScore {
            parts.append("score \(score.formatted(.number.precision(.fractionLength(3)).grouping(.never)))")
        }
        if let t = f.trajectory {
            parts.append("\(t.direction) trajectory")
        }
        return parts.joined(separator: ", ")
    }

    /// Produces the portfolio narrative — a single reduce over deterministic facts.
    public func narrate(_ input: NarrativeInput) async throws -> String {
        try await reduce(input)
    }

    // MARK: - Instructions & aggregates

    static let leafInstructions = """
    You extract a one-line quality-gate status for ONE project. State pass/fail, \
    the weighted score, and the single most notable trajectory or anomaly. Only use \
    facts given. Never invent metrics. No preamble, no emoji.
    """

    static let reduceInstructions = """
    You are the analyst voice of a Swift static-analysis quality-gate dashboard \
    (~50 projects). Given portfolio aggregates and a one-line status per project, \
    write a portfolio narrative in markdown with ## headers: lead with current state \
    (pass/fail, mean score), name the strongest improvers and confirmed decliners, \
    cross-reference project families that share a name prefix (parent app vs its \
    libraries), and end with 3-4 prioritized guidance items. Flag trends resting on \
    few data points. Only use facts provided. No emoji. 350-500 words.
    """

    static func aggregateSummary(_ pulse: InstitutionalPulse) -> String {
        let s = pulse.statistics
        var lines: [String] = []
        let label = pulse.label ?? pulse.weekLabel
        if let snap = pulse.currentSnapshot {
            lines.append("Projects: \(snap.totalProjects); passing=\(snap.passingProjects); failing=\(snap.failingProjects); overrides=\(snap.totalOverrides)")
        } else {
            lines.append("Projects: \(pulse.projects.count)")
        }
        let vals = (s.weightedScores ?? [:]).values.sorted()
        let count = vals.count
        if count > 0 { // fp-safety: guards the Double(count) and /2.0 divisors below
            let mean = vals.reduce(0, +) / Double(count)
            let median = count % 2 == 0 ? (vals[count / 2 - 1] + vals[count / 2]) / 2.0 : vals[count / 2]
            lines.append("Weighted score mean=\(fmt(mean)) median=\(fmt(median)) n=\(count) min=\(fmt(vals[0])) max=\(fmt(vals[count - 1]))")
        }
        lines.append("Window: gateRuns=\(s.totalGateRuns) passed=\(s.passedRuns) failed=\(s.failedRuns) overrides=\(s.totalOverrides)")
        let fc = s.failuresByChecker.sorted { $0.value > $1.value }.prefix(6)
        if !fc.isEmpty {
            lines.append("Top failing checkers: " + fc.map { "\($0.key)(\($0.value))" }.joined(separator: ", "))
        }
        return "# Portfolio aggregates \(label)\n" + lines.joined(separator: "\n")
    }

    private static func fmt(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3)).grouping(.never))
    }
}
