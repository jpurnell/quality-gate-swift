import Foundation
import Testing
import CorpusKit
@testable import NarrativeCore

@Suite("AnthropicNarrativeProvider — availability and prompt wiring")
struct AnthropicNarrativeProviderTests {
    /// Echoes tagged fragments of what it was asked to send, so tests can assert
    /// the provider wired the built prompts through without a real network.
    private struct EchoTransport: NarrativeTransport {
        func send(system: String, user: String, model: String, apiKey: String) async throws -> String {
            "MODEL=\(model)\nSYS_HAS_ANALYST=\(system.contains("institutional quality analyst"))\nUSER=\(user)"
        }
    }

    private func input() -> NarrativeInput {
        let pulse = PulseFixtures.pulse(
            projects: ["Foo"],
            statistics: PulseFixtures.emptyStats(weightedScores: ["Foo": 0.9])
        )
        return NarrativeInput(pulse: pulse, previousPulse: nil, workLogsByProject: [:])
    }

    @Test("Unavailable when key is nil or empty; available with a key")
    func availability() {
        #expect(AnthropicNarrativeProvider(apiKey: nil).isAvailable(for: input()) == false)
        #expect(AnthropicNarrativeProvider(apiKey: "").isAvailable(for: input()) == false)
        #expect(AnthropicNarrativeProvider(apiKey: "sk-abc").isAvailable(for: input()) == true)
    }

    @Test("Source tag is claude")
    func sourceTag() {
        #expect(AnthropicNarrativeProvider(apiKey: "k").source == .claude)
    }

    @Test("narrate builds system+user prompts and sends them via the transport")
    func narrateWiresPrompts() async throws {
        let provider = AnthropicNarrativeProvider(apiKey: "k", model: "test-model", transport: EchoTransport())
        let out = try await provider.narrate(input())
        #expect(out.contains("MODEL=test-model"))
        #expect(out.contains("SYS_HAS_ANALYST=true"))
        #expect(out.contains("## Pulse Data: 2026-07-29"))   // user prompt built from the pulse
        #expect(out.contains("Weighted Quality Scores"))
    }

    @Test("narrate throws when key is missing")
    func narrateThrowsWithoutKey() async {
        let provider = AnthropicNarrativeProvider(apiKey: nil, transport: EchoTransport())
        await #expect(throws: AnthropicTransportError.self) {
            _ = try await provider.narrate(input())
        }
    }
}

@Suite("FoundationModelsNarrativeProvider — map-reduce orchestration")
struct FoundationModelsNarrativeProviderTests {
    /// Deterministic stand-in for the on-device model: returns the prompt it was
    /// handed, tagged, so the map-reduce wiring is observable without a model.
    private struct EchoGenerator: OnDeviceNarrativeGenerator {
        var available: Bool = true
        var isAvailable: Bool { available }
        func generate(instructions: String, prompt: String) async throws -> String {
            prompt
        }
    }

    private func input() -> NarrativeInput {
        let snapshot = CurrentSnapshot(
            projects: [PulseFixtures.status("Alpha"), PulseFixtures.status("Beta")],
            totalOverrides: 0, totalComplianceCount: 0, failingCheckers: [:]
        )
        let pulse = PulseFixtures.pulse(
            projects: ["Alpha", "Beta"],
            statistics: PulseFixtures.emptyStats(weightedScores: ["Alpha": 0.9, "Beta": 0.8]),
            currentSnapshot: snapshot
        )
        return NarrativeInput(pulse: pulse, previousPulse: nil, workLogsByProject: [:])
    }

    @Test("Availability reflects the underlying generator")
    func availability() {
        #expect(FoundationModelsNarrativeProvider(generator: EchoGenerator(available: false)).isAvailable(for: input()) == false)
        #expect(FoundationModelsNarrativeProvider(generator: EchoGenerator(available: true)).isAvailable(for: input()) == true)
    }

    @Test("Source tag is onDeviceLLM")
    func sourceTag() {
        #expect(FoundationModelsNarrativeProvider(generator: EchoGenerator()).source == .onDeviceLLM)
    }

    @Test("map produces one narrative per project, in ID order, each isolated")
    func mapPerProject() async throws {
        let provider = FoundationModelsNarrativeProvider(generator: EchoGenerator())
        let leaves = try await provider.mapProjects(input())
        #expect(leaves.map(\.projectID) == ["Alpha", "Beta"])
        // Each leaf's text (the echoed shard) names only its own project.
        let alpha = leaves.first { $0.projectID == "Alpha" }
        #expect(alpha?.text.contains("# Project: Alpha") == true)
        #expect(alpha?.text.contains("Beta") == false)
    }

    @Test("reduce feeds deterministic PASS/score fact-lines, not model prose")
    func reduceUsesDeterministicFactLines() async throws {
        // EchoGenerator returns the prompt it was handed, so we can inspect it.
        let provider = FoundationModelsNarrativeProvider(generator: EchoGenerator())
        let out = try await provider.reduce(input())
        #expect(out.contains("## Portfolio Aggregates"))
        #expect(out.contains("## Per-project status (2)"))
        #expect(out.contains("- Alpha: PASS score=0.900"))
        #expect(out.contains("- Beta: PASS score=0.800"))
    }

    @Test("narrate is a single reduce over deterministic facts (no map pass)")
    func narrateIsReduceOnly() async throws {
        let provider = FoundationModelsNarrativeProvider(generator: EchoGenerator())
        let out = try await provider.narrate(input())
        #expect(out.contains("## Per-project status (2)"))
        #expect(out.contains("PASS score=0.900"))
    }

    @Test("reduceLine always states PASS/FAIL and score; adds trajectory + top anomaly")
    func reduceLineDeterministic() {
        let passing = ProjectFacts(projectID: "A", passing: true, weightedScore: 0.87)
        #expect(FoundationModelsNarrativeProvider.reduceLine(passing) == "PASS score=0.870")

        let failing = ProjectFacts(projectID: "B", passing: false, failedCheckers: ["test", "doc-lint"], weightedScore: 0.5)
        #expect(FoundationModelsNarrativeProvider.reduceLine(failing).hasPrefix("FAIL(test,doc-lint) score=0.500"))

        let rich = ProjectFacts(
            projectID: "C", passing: true, weightedScore: 0.8,
            trajectory: TrajectoryFacts(direction: "declining", slope: -0.005, rSquared: 0.5, sampleSize: 24, inflectionDetected: false, recentSlope: nil),
            anomalies: [AnomalyFacts(metric: "passRate", direction: "positive", observedValue: 0.5, expectedValue: 0.04, zScore: 4.2, gatedSeverity: "confirmed", actionability: "investigate")]
        )
        let line = FoundationModelsNarrativeProvider.reduceLine(rich, maxChars: 200)
        #expect(line.contains("declining"))
        #expect(line.contains("anom passRate z=4.2"))
    }

    /// Always throws — stands in for a model that errors on every call.
    private struct ThrowingGenerator: OnDeviceNarrativeGenerator {
        struct Boom: Error {}
        var isAvailable: Bool { true }
        func generate(instructions: String, prompt: String) async throws -> String { throw Boom() }
    }

    @Test("A project's model error falls back to a deterministic leaf, not a total failure")
    func mapResilientToPerLeafError() async throws {
        let provider = FoundationModelsNarrativeProvider(generator: ThrowingGenerator())
        let leaves = try await provider.mapProjects(input())
        #expect(leaves.count == 2)
        // Alpha is passing with score 0.9 → deterministic fallback names those facts.
        let alpha = leaves.first { $0.projectID == "Alpha" }
        #expect(alpha?.text.contains("passing") == true)
        #expect(alpha?.text.contains("0.900") == true)
        #expect(alpha?.text.isEmpty == false)
    }

    @Test("sanitize strips hallucinated tool-call preamble, keeps the narrative")
    func sanitizeStripsToolCalls() {
        let dirty = """
        Tool call: {tool_name: "extract_project_families", arguments: {"prefix":"X"}}
        tool_call: {tool_name: "get_status"}

        ## Portfolio Current State
        Pass rate: 100%.
        """
        let clean = FoundationModelsNarrativeProvider.sanitize(dirty)
        #expect(clean.hasPrefix("## Portfolio Current State"))
        #expect(clean.contains("tool_name") == false)
    }

    @Test("sanitize reduces an all-tool-call line to empty (triggers fallback)")
    func sanitizeAllJunkIsEmpty() {
        let junk = "tool call: {name: \"a\"} | tool call: {name: \"b\"} | tool call: {name: \"c\"}"
        #expect(FoundationModelsNarrativeProvider.sanitize(junk).isEmpty)
    }

    @Test("sanitize leaves clean narrative untouched")
    func sanitizeKeepsCleanContent() {
        let good = "## Summary\nAll 56 projects passing."
        #expect(FoundationModelsNarrativeProvider.sanitize(good) == good)
    }

    @Test("reduceLine is bounded so ~50 lines stay inside the context window")
    func reduceLineBounded() {
        let facts = ProjectFacts(
            projectID: "VeryLongProjectNameThatGoesOnAndOn", passing: false,
            failedCheckers: ["a", "b", "c", "d"], weightedScore: 0.123,
            trajectory: TrajectoryFacts(direction: "declining", slope: -0.0099, rSquared: 0.9, sampleSize: 30, inflectionDetected: true, recentSlope: -0.02),
            anomalies: [AnomalyFacts(metric: "passRate", direction: "positive", observedValue: 0.5, expectedValue: 0.04, zScore: 9.9, gatedSeverity: "confirmed", actionability: "investigate")]
        )
        #expect(FoundationModelsNarrativeProvider.reduceLine(facts, maxChars: 72).count <= 72)
    }
}

@Suite("PreservedNarrativeProvider — carry-forward rung")
struct PreservedNarrativeProviderTests {
    private func input(priorNarrative: String?) -> NarrativeInput {
        let current = PulseFixtures.pulse(projects: ["Foo"])
        let prior = PulseFixtures.pulse(projects: ["Foo"], narrative: priorNarrative)
        return NarrativeInput(pulse: current, previousPulse: prior, workLogsByProject: [:])
    }

    @Test("Available only when a non-empty prior narrative exists")
    func availability() {
        let provider = PreservedNarrativeProvider()
        #expect(provider.isAvailable(for: input(priorNarrative: "yesterday's words")) == true)
        #expect(provider.isAvailable(for: input(priorNarrative: nil)) == false)
        #expect(provider.isAvailable(for: input(priorNarrative: "   \n ")) == false)
    }

    @Test("Carries the prior narrative forward verbatim, tagged preservedLLM")
    func carriesForward() async throws {
        let provider = PreservedNarrativeProvider()
        #expect(provider.source == .preservedLLM)
        let out = try await provider.narrate(input(priorNarrative: "yesterday's words"))
        #expect(out == "yesterday's words")
    }

    @Test("Throws when there is no prior narrative")
    func throwsWithoutPrior() async {
        await #expect(throws: PreservedNarrativeError.self) {
            _ = try await PreservedNarrativeProvider().narrate(input(priorNarrative: nil))
        }
    }
}

@Suite("NarrativePersistence — per-project docs as a rule")
struct NarrativePersistenceTests {
    // Deterministic per-test temp dir — the test name keeps runs isolated without
    // any randomness (tests must be reproducible).
    private func tempDir(_ name: String) -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("narr-test-\(ProcessInfo.processInfo.processIdentifier)-\(name)")
    }

    @Test("Writes one document per project with its content")
    func writesPerProject() throws {
        let dir = tempDir("writesPerProject")
        try? FileManager.default.removeItem(atPath: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let persistence = NarrativePersistence()
        let paths = try persistence.writePerProject(
            [ProjectNarrative(projectID: "Beta", text: "beta body"), ProjectNarrative(projectID: "Alpha", text: "alpha body")],
            pulseDir: dir
        )
        #expect(paths.count == 2)
        // Sorted by ID → Alpha first.
        #expect(paths.first?.hasSuffix("projects/Alpha.md") == true)
        let alpha = try String(contentsOfFile: (dir as NSString).appendingPathComponent("projects/Alpha.md"), encoding: .utf8)
        #expect(alpha.contains("# Alpha"))
        #expect(alpha.contains("alpha body"))
    }

    @Test("Project IDs with path separators are sanitized")
    func sanitizesNames() {
        #expect(NarrativePersistence.safeName("a/b:c") == "a_b_c")
        #expect(NarrativePersistence.safeName("WineTaster 4") == "WineTaster 4")
    }

    @Test("Writes the portfolio narrative to its path")
    func writesPortfolio() throws {
        let dir = tempDir("writesPortfolio")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("NARRATIVE.md")
        try NarrativePersistence().writePortfolio("hello portfolio", to: path)
        let read = try String(contentsOfFile: path, encoding: .utf8)
        #expect(read == "hello portfolio")
    }
}
