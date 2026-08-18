import Testing
import Foundation
@testable import IJSAggregator
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes

@Suite("ProjectSummary")
struct ProjectSummaryTests {
    @Test("Computes pass rate correctly")
    func computesPassRate() {
        let runs = makeRuns(statuses: [true, true, false, true])
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(abs(summary.passRate - 0.75) < 1e-6)
    }

    @Test("Latest status reflects most recent run")
    func latestStatus() {
        let runs = makeRuns(statuses: [true, true, false])
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(summary.latestPassed == false)
    }

    @Test("Identifies worst-performing checker")
    func worstChecker() {
        let runs = makeRunsWithCheckers(
            checkerResults: [
                ["safety": true, "build": false],
                ["safety": true, "build": false],
                ["safety": false, "build": true],
            ]
        )
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(summary.worstChecker == "build")
    }

    @Test("Checker breakdown shows per-checker pass rates")
    func checkerBreakdown() throws {
        let runs = makeRunsWithCheckers(
            checkerResults: [
                ["safety": true, "build": false],
                ["safety": true, "build": true],
            ]
        )
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(abs(try #require(summary.checkerPassRates["safety"]) - 1.0) < 1e-6)
        #expect(abs(try #require(summary.checkerPassRates["build"]) - 0.5) < 1e-6)
    }

    @Test("Override count accumulates across runs")
    func overrideCount() {
        let runs = makeRuns(statuses: [true, true], overrideCountPerRun: 3)
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(summary.totalOverrides == 6)
    }

    @Test("Handles single run")
    func singleRun() {
        let runs = makeRuns(statuses: [true])
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(abs(summary.passRate - 1.0) < 1e-6)
        #expect(summary.runCount == 1)
    }

    @Test("Handles empty runs")
    func emptyRuns() {
        let summary = ProjectSummary.compute(projectID: "test", from: [])
        #expect(abs(summary.passRate) < 1e-6)
        #expect(summary.runCount == 0)
    }

    @Test("Latest checker status uses most recent run per checker")
    func latestCheckerPerRun() {
        let runs = makeRunsWithCheckers(
            checkerResults: [
                ["safety": true, "build": true, "concurrency": true],
                ["safety": false],
            ]
        )
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(summary.latestCheckerPassed["safety"] == false)
        #expect(summary.latestCheckerPassed["build"] == true)
        #expect(summary.latestCheckerPassed["concurrency"] == true)
    }

    // MARK: - Lifecycle

    @Test("Default lifecycle is active")
    func defaultLifecycleActive() {
        let runs = makeRuns(statuses: [true])
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(summary.lifecycle == .active)
    }

    @Test("Lifecycle can be set to sunset")
    func lifecycleSunset() {
        let runs = makeRuns(statuses: [true])
        let summary = ProjectSummary.compute(projectID: "test", from: runs, lifecycle: .sunset)
        #expect(summary.lifecycle == .sunset)
    }

    @Test("Empty runs preserves lifecycle")
    func emptyRunsPreservesLifecycle() {
        let summary = ProjectSummary.compute(projectID: "test", from: [], lifecycle: .sunset)
        #expect(summary.lifecycle == .sunset)
        #expect(summary.runCount == 0)
    }

    // MARK: - Run scope honesty (0.1)

    @Test("Pass rate and full-confirmation count full runs only, not a green subset")
    func subsetRunsDoNotMovePassRate() {
        let runs = [
            makeScopedRun(index: 0, checkers: ["safety": true], scope: .full),
            makeScopedRun(index: 1, checkers: ["safety": false], scope: .full),
            makeScopedRun(index: 2, checkers: ["legibility": true], scope: .subset(checkers: ["legibility"])),
        ]
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        // Historical pass rate is over full runs only: 1 of 2 passed.
        #expect(abs(summary.passRate - 0.5) < 1e-6)
        #expect(summary.runCount == 2)
        #expect(summary.partialRunCount == 1)
        // safety's latest standard result is still failing, so the composite
        // gate is not green — and it was never confirmed by a full run.
        #expect(summary.latestPassed == false)
        #expect(summary.latestFullPassed == false)
    }

    @Test("Subset runs are real evidence for the checkers that ran")
    func subsetRunsInformCheckerRates() {
        let runs = [
            makeScopedRun(index: 0, checkers: ["safety": true, "legibility": false], scope: .full),
            makeScopedRun(index: 1, checkers: ["legibility": true], scope: .subset(checkers: ["legibility"])),
        ]
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        let legibilityRate = summary.checkerPassRates["legibility"] ?? -1
        #expect(abs(legibilityRate - 0.5) < 1e-6)
        #expect(summary.latestCheckerPassed["legibility"] == true)
    }

    @Test("A targeted subset fix flips the composite gate green but not full-confirmed")
    func subsetFixMakesCompositeGreen() {
        // The BusinessMathPro / geo-audit case: the last full run failed one
        // checker; a targeted `--check` re-ran just that checker and it passed.
        let runs = [
            makeScopedRun(index: 0, checkers: ["safety": true, "build": false], scope: .full),
            makeScopedRun(index: 1, checkers: ["build": true], scope: .subset(checkers: ["build"])),
        ]
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        // Every checker's latest standard result now passes → overview green.
        #expect(summary.latestPassed == true)
        // But no full run has confirmed the whole gate → render ✓*, not ✓.
        #expect(summary.latestFullPassed == false)
    }

    @Test("A green full run with nothing newer is fully confirmed")
    func fullGreenIsFullyConfirmed() {
        let runs = [
            makeScopedRun(index: 0, checkers: ["safety": true, "build": true], scope: .full),
        ]
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(summary.latestPassed == true)
        #expect(summary.latestFullPassed == true)
    }

    @Test("A newer subset failure overrides a stale full-green")
    func newerSubsetFailureFails() {
        let runs = [
            makeScopedRun(index: 0, checkers: ["safety": true, "build": true], scope: .full),
            makeScopedRun(index: 1, checkers: ["build": false], scope: .subset(checkers: ["build"])),
        ]
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(summary.latestPassed == false)
    }

    @Test("Advisory surveys never flip the composite gate green")
    func advisoryRunsDoNotConfirm() {
        let runs = [
            makeScopedRun(index: 0, checkers: ["safety": false], scope: .full),
            makeScopedRun(index: 1, checkers: ["safety": true], scope: .full, gateMode: .advisory),
        ]
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        // The advisory survey is not a gate, so safety's latest *standard*
        // result is still the failing full run.
        #expect(summary.latestCheckerPassed["safety"] == false)
        #expect(summary.latestPassed == false)
    }

    @Test("An all-subset history is green if every checker's latest run passed, but never full-confirmed")
    func allSubsetHistory() {
        let runs = [
            makeScopedRun(index: 0, checkers: ["legibility": true], scope: .subset(checkers: ["legibility"])),
            makeScopedRun(index: 1, checkers: ["safety": true], scope: .subset(checkers: ["safety"])),
        ]
        let summary = ProjectSummary.compute(projectID: "test", from: runs)
        #expect(summary.runCount == 0)
        #expect(summary.partialRunCount == 2)
        #expect(abs(summary.passRate - 0.0) < 1e-6)
        // Composite of the two subset runs: both checkers pass → green (✓*)…
        #expect(summary.latestPassed == true)
        // …but no full run confirmed the whole gate.
        #expect(summary.latestFullPassed == false)
    }
}

// MARK: - Helpers

private func makeScopedRun(
    index: Int,
    checkers: [String: Bool],
    scope: RunScope,
    gateMode: GateMode = .standard
) -> TimestampedRun {
    let results = checkers.map { id, passed in
        CheckResult(
            checkerId: id,
            status: passed ? .passed : .failed,
            diagnostics: [],
            duration: .milliseconds(100)
        )
    }
    return TimestampedRun(
        metadata: CheckResultMetadata(
            projectID: "test",
            timestamp: Date(timeIntervalSince1970: Double(1747267200 + index * 3600)),
            environment: .local,
            decisionOwner: "test",
            results: results,
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil,
            runScope: scope,
            gateMode: gateMode
        )
    )
}

private func makeRuns(statuses: [Bool], overrideCountPerRun: Int = 0) -> [TimestampedRun] {
    statuses.enumerated().map { index, allPassed in
        let overrides = (0..<overrideCountPerRun).map { _ in
            OverrideRecord(
                diagnosticOverride: DiagnosticOverride(ruleId: "test", justification: "test", filePath: "f.swift", lineNumber: 1),
                author: "test",
                riskTier: .operational,
                authorityLevel: .peer
            )
        }
        return TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: "test",
                timestamp: Date(timeIntervalSince1970: Double(1747267200 + index * 3600)),
                environment: .local,
                decisionOwner: "test",
                results: [
                    CheckResult(
                        checkerId: "safety",
                        status: allPassed ? .passed : .failed,
                        diagnostics: [],
                        duration: .milliseconds(100)
                    ),
                ],
                overrides: overrides,
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
        )
    }
}

private func makeRunsWithCheckers(checkerResults: [[String: Bool]]) -> [TimestampedRun] {
    checkerResults.enumerated().map { index, checkers in
        let results = checkers.map { id, passed in
            CheckResult(
                checkerId: id,
                status: passed ? .passed : .failed,
                diagnostics: [],
                duration: .milliseconds(100)
            )
        }
        return TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: "test",
                timestamp: Date(timeIntervalSince1970: Double(1747267200 + index * 3600)),
                environment: .local,
                decisionOwner: "test",
                results: results,
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
        )
    }
}
