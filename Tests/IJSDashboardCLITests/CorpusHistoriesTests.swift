import Foundation
import Testing
import CorpusKit
import IJSDashboardCore
import QualityGateTypes
@testable import IJSDashboardCLI

/// What the terminal dashboard holds between refreshes.
///
/// It used to hold every run of every project, findings included, and replace all of it every
/// thirty seconds. `CorpusHistories` holds each project's history without diagnostics plus the
/// findings for its present state, and a refresh re-reads only the projects whose history
/// changed.
@Suite("Corpus histories")
struct CorpusHistoriesTests {

    @Test("A first refresh loads every project, without diagnostics in the history")
    func firstRefreshLoadsAll() async throws {
        let corpus = try TempCorpus()
        defer { corpus.remove() }
        try await corpus.write(project: "alpha", minute: 0, notes: 2)
        try await corpus.write(project: "beta", minute: 0, notes: 0)
        var histories = CorpusHistories()

        let changed = try histories.refresh(from: corpus.reader)

        #expect(changed == ["alpha", "beta"])
        #expect(histories.runs["alpha"]?.count == 1)
        #expect(histories.runs["alpha"]?.first?.metadata.results.first?.diagnostics.isEmpty == true)
        #expect(histories.latestResults["alpha"]?.first?.diagnostics.count == 2)
        #expect(histories.latestResults["beta"]?.first?.diagnostics.isEmpty == true)
    }

    @Test("A refresh with nothing new re-reads nothing")
    func idleRefreshChangesNothing() async throws {
        let corpus = try TempCorpus()
        defer { corpus.remove() }
        try await corpus.write(project: "alpha", minute: 0, notes: 1)
        var histories = CorpusHistories()
        _ = try histories.refresh(from: corpus.reader)

        let changed = try histories.refresh(from: corpus.reader)

        #expect(changed.isEmpty)
        #expect(histories.runs["alpha"]?.count == 1)
    }

    @Test("A new run re-reads its project and leaves the others alone")
    func newRunRefreshesOneProject() async throws {
        let corpus = try TempCorpus()
        defer { corpus.remove() }
        try await corpus.write(project: "alpha", minute: 0, notes: 1)
        try await corpus.write(project: "beta", minute: 0, notes: 1)
        var histories = CorpusHistories()
        _ = try histories.refresh(from: corpus.reader)

        try await corpus.write(project: "beta", minute: 1, notes: 3)
        let changed = try histories.refresh(from: corpus.reader)

        #expect(changed == ["beta"])
        #expect(histories.runs["beta"]?.count == 2)
        #expect(histories.latestResults["beta"]?.first?.diagnostics.count == 3)
        #expect(histories.runs["alpha"]?.count == 1)
    }

    @Test("A project removed from the corpus is dropped")
    func removedProjectDropped() async throws {
        let corpus = try TempCorpus()
        defer { corpus.remove() }
        try await corpus.write(project: "alpha", minute: 0, notes: 0)
        try await corpus.write(project: "beta", minute: 0, notes: 0)
        var histories = CorpusHistories()
        _ = try histories.refresh(from: corpus.reader)

        try FileManager.default.removeItem(at: corpus.base.appendingPathComponent("telemetry/beta"))
        let changed = try histories.refresh(from: corpus.reader)

        #expect(changed == ["beta"])
        #expect(histories.runs["beta"] == nil)
        #expect(histories.latestResults["beta"] == nil)
        #expect(histories.runs["alpha"]?.count == 1)
    }
}

/// A throwaway corpus whose runs are written through `TelemetryWriter`.
private struct TempCorpus {
    let base: URL
    var reader: CorpusReader { CorpusReader(corpusPath: base.path) }

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-histories-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("telemetry", isDirectory: true),
            withIntermediateDirectories: true)
    }

    func write(project: String, minute: Int, notes: Int) async throws {
        let metadata = CheckResultMetadata(
            projectID: project,
            timestamp: Date(timeIntervalSince1970: Double(1_777_384_800 + minute * 60)),
            environment: .local,
            decisionOwner: "tester",
            results: [
                CheckResult(
                    checkerId: "legibility", status: .passed,
                    diagnostics: (0..<notes).map {
                        Diagnostic(severity: .note, message: "note \($0)", filePath: "/src/A.swift",
                                   lineNumber: $0 + 1, ruleId: "legibility:reserved")
                    },
                    duration: .milliseconds(40)),
            ],
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil
        )
        try await TelemetryWriter().write(
            metadata: metadata, calibrations: [],
            to: CorpusPath(basePath: base.path, projectID: project))
    }

    func remove() {
        do {
            try FileManager.default.removeItem(at: base)
        } catch {
            // A leftover temp directory fails no assertion; the OS reclaims it.
            print("TempCorpus cleanup skipped: \(error.localizedDescription)")
        }
    }
}
