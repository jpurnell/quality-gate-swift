import Foundation
import Testing
@testable import QualityGateCore

/// A checker that silences one finding with a marker and counts how often it really ran.
private struct MarkerChecker: QualityChecker {
    let id = "marker-checker"
    let name = "Marker checker"
    let summary = "Test double; not a documented checker"
    let category = CheckerCategory.specialty
    let kind = CheckerKind.code
    let effect = CheckerEffect.readOnly
    let executesProjectCode = false
    let inputFile: String
    let runs: RunCounter

    func cacheInputs(configuration: Configuration) -> CacheInputs? {
        CacheInputs(files: [inputFile])
    }

    func check(configuration: Configuration) async throws -> CheckResult {
        await runs.increment()
        return CheckResult(
            checkerId: id,
            status: .passed,
            diagnostics: [
                Diagnostic(
                    severity: .warning, message: "hidden by config", filePath: "/repo/A.swift",
                    lineNumber: 20, ruleId: "marker.hidden")
            ],
            overrides: [
                .inlineMarker(
                    form: "// silent:", ruleId: "logging.silent-try", filePath: "/repo/A.swift",
                    findingLine: 3, markerLine: 3, comment: "try? f() // silent: best effort")
            ],
            complianceRecords: [
                ComplianceRecord(
                    ruleId: "pointer-escape", annotation: "Allowed by configuration: memcpy",
                    filePath: "/repo/A.swift", lineNumber: 9)
            ],
            duration: .zero)
    }
}

private actor RunCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// What a run was told not to raise is the same whether the checker ran or was replayed.
///
/// `markReplayed` rebuilt the result from four of its six fields. `overrides` and
/// `complianceRecords` were the two left out, so the first run of a tree listed every marker
/// and every later run of the same tree listed none — the totals were a function of whether
/// the cache was warm.
@Suite("Suppression records survive a cache replay")
struct SuppressionCacheReplayTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-suppression-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Overrides, compliance records and totals are identical on the replay")
    func replayCarriesTheSameRecords() async throws {
        let dir = try tempDir()
        let input = dir.appendingPathComponent("in.txt")
        try "v1".write(to: input, atomically: true, encoding: .utf8)
        let cache = ResultCache(directory: dir.appendingPathComponent("cache"))
        let runs = RunCounter()
        let checker = MarkerChecker(inputFile: input.path, runs: runs)
        let processor = OverrideProcessor(overrides: ["marker.hidden": .off])

        func run() async -> CheckResult? {
            await CheckerRunner(maxConcurrency: 2).run(
                checkers: [checker], configuration: Configuration(),
                strict: false, continueOnFailure: true,
                cache: cache, gateHash: "gate", useCache: true,
                transform: { processor.apply(to: $0) }
            ).results.first
        }

        let fresh = try #require(await run())
        let replayed = try #require(await run())

        #expect(await runs.count == 1)
        #expect(replayed.diagnostics.first?.ruleId == "cache.replayed")

        #expect(fresh.overrides.count == 2)
        #expect(replayed.overrides == fresh.overrides)
        #expect(replayed.complianceRecords == fresh.complianceRecords)
        #expect(replayed.complianceRecords.count == 1)

        let freshLedger = SuppressionLedger(results: [fresh])
        let replayedLedger = SuppressionLedger(results: [replayed])
        #expect(freshLedger.overall.suppressed == 2)
        #expect(freshLedger.overall.suppressedByForm == ["// silent:": 1, "config overrides: off": 1])
        #expect(replayedLedger.overall == freshLedger.overall)
        #expect(replayedLedger.checkers.first?.records == freshLedger.checkers.first?.records)
    }
}
