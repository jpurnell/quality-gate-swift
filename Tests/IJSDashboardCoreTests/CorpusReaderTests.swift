import Testing
import Foundation
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes

@Suite("CorpusReader")
struct CorpusReaderTests {
    @Test("Discovers projects from directory structure")
    func discoversProjects() throws {
        let corpus = try makeTestCorpus(projects: ["alpha", "beta"])
        let reader = CorpusReader(corpusPath: corpus)
        let projects = try reader.discoverProjects()
        #expect(projects.sorted() == ["alpha", "beta"])
    }

    @Test("Decodes valid metadata JSON")
    func decodesMetadata() throws {
        let corpus = try makeTestCorpus(projects: ["alpha"], runsPerProject: 1)
        let reader = CorpusReader(corpusPath: corpus)
        let runs = try reader.loadRuns(for: "alpha")
        #expect(runs.count == 1)
        #expect(runs[0].metadata.projectID == "alpha")
    }

    @Test("Skips malformed JSON with warning")
    func skipsMalformedJSON() throws {
        let corpus = try makeTestCorpus(projects: [])
        let projectDir = "\(corpus)/telemetry/broken/2026-05-15"
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        try "not json".write(toFile: "\(projectDir)/120000_metadata.json", atomically: true, encoding: .utf8)

        let reader = CorpusReader(corpusPath: corpus)
        let runs = try reader.loadRuns(for: "broken")
        #expect(runs.isEmpty)
    }

    @Test("Handles empty corpus directory")
    func handlesEmptyCorpus() throws {
        let corpus = try makeTestCorpus(projects: [])
        let reader = CorpusReader(corpusPath: corpus)
        let projects = try reader.discoverProjects()
        #expect(projects.isEmpty)
    }

    @Test("Loads all runs sorted by timestamp")
    func loadsSortedRuns() throws {
        let corpus = try makeTestCorpus(projects: ["proj"], runsPerProject: 3)
        let reader = CorpusReader(corpusPath: corpus)
        let runs = try reader.loadRuns(for: "proj")
        #expect(runs.count == 3)
        for i in 0..<runs.count - 1 {
            #expect(runs[i].metadata.timestamp <= runs[i + 1].metadata.timestamp)
        }
    }

    @Test("Loads all projects at once")
    func loadsAllProjects() throws {
        let corpus = try makeTestCorpus(projects: ["a", "b", "c"], runsPerProject: 2)
        let reader = CorpusReader(corpusPath: corpus)
        let all = try reader.loadAll()
        #expect(all.count == 3)
        #expect(all["a"]?.count == 2)
        #expect(all["b"]?.count == 2)
    }
}

// MARK: - Test Helpers

private func makeTestCorpus(projects: [String], runsPerProject: Int = 0) throws -> String {
    let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
    let fm = FileManager.default
    try fm.createDirectory(atPath: "\(tmp)/telemetry", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: "\(tmp)/pulse", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: "\(tmp)/snapshots", withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    for project in projects {
        let dateDir = "\(tmp)/telemetry/\(project)/2026-05-15"
        try fm.createDirectory(atPath: dateDir, withIntermediateDirectories: true)

        for i in 0..<runsPerProject {
            let timestamp = String(format: "%02d0000", i + 10)
            let metadata = CheckResultMetadata(
                projectID: project,
                timestamp: Date(timeIntervalSince1970: Double(1747267200 + i * 3600)),
                environment: .local,
                decisionOwner: "test",
                results: [
                    makeCheckResult(id: "safety", passed: true),
                    makeCheckResult(id: "build", passed: i % 2 == 0),
                ],
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
            let data = try encoder.encode(metadata)
            try data.write(to: URL(fileURLWithPath: "\(dateDir)/\(timestamp)_metadata.json"))
        }
    }

    return tmp
}

private func makeCheckResult(id: String, passed: Bool) -> CheckResult {
    CheckResult(
        checkerId: id,
        status: passed ? .passed : .failed,
        diagnostics: [],
        duration: .milliseconds(100)
    )
}
