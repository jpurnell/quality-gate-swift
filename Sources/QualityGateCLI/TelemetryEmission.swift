import Foundation
#if canImport(os)
import os
#endif
import ComplexityAnalyzer
import IJSSensor
import IJSAggregator
import LegibilityAnalyzer
import QualityGateCore

/// The single post-run telemetry step (Phase 0.1).
///
/// Called after reporting on *every* invocation with a configured corpus
/// path — full gate or `--check <subset>`. The run's scope is recorded in
/// the metadata so readers can keep gate statistics honest; sidecar
/// emitters (complexity, orientation) run on subset runs only when their
/// checker actually ran, preserving the cost profile of tiny runs.
enum TelemetryEmission {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "TelemetryEmission")

    /// Emits metadata, calibrations, work-events, and sidecar reports to the
    /// configured corpus. Best-effort by contract: a telemetry failure must
    /// never fail the gate.
    ///
    /// `identityKind` distinguishes foreign runs (Phase 1): they record under
    /// the upstream identity but dashboards group them separately.
    static func emit(
        configuration: Configuration,
        results: [CheckResult],
        runScope: RunScope,
        identityKind: IdentityKind = .resident,
        verbose: Bool
    ) async {
        guard let corpusPath = configuration.consistency.corpusPath else { return }

        let ijsConfig = configuration.consistency
        let projectID = EffectiveProjectID.resolve(consistency: ijsConfig)
        let riskTier = RiskTier(rawValue: ijsConfig.defaultRiskTier) ?? .operational
        let consistencyResult = results.first { $0.checkerId == "consistency" }
        let consistencyScore = consistencyResult?.diagnostics
            .first { $0.ruleId == "consistency-score" }
            .flatMap { diag -> Double? in
                let parts = diag.message.split(separator: " ")
                guard let idx = parts.firstIndex(of: "score:"),
                      idx + 1 < parts.count else { return nil }
                return Double(parts[idx + 1])
            }

        let isCI = ProcessInfo.processInfo.environment["CI"] != nil
        let author = ProcessInfo.processInfo.environment["USER"] ?? "local"
        let allOverrides = results.flatMap(\.overrides)
        let complianceCount = results.map(\.complianceRecords.count).reduce(0, +)
        let overrideRecords = allOverrides.map { override in
            OverrideRecord(
                diagnosticOverride: override,
                author: author,
                riskTier: riskTier,
                authorityLevel: riskTier.requiredAuthority
            )
        }

        let runTimestamp = Date()

        // Capture git provenance so metric snapshots can be joined to the
        // human work behind them. Best-effort: a provenance failure must
        // never fail the gate.
        let gatedProjectDir = FileManager.default.currentDirectoryPath
        let corpus = CorpusPath(basePath: corpusPath, projectID: projectID)
        let writer = TelemetryWriter()
        // silent: an unreadable work-log just means no baseline SHA — provenance is best-effort
        let lastRecordedSHA = (try? await writer.readWorkLog(from: corpus))?
            .last(where: { $0.commitSHA != nil })?.commitSHA
        let provenance = GitProvenance.capture(
            repoPath: gatedProjectDir,
            sinceSHA: lastRecordedSHA
        )

        let metadata = CheckResultMetadata(
            projectID: projectID,
            timestamp: runTimestamp,
            environment: isCI ? .ci : .local,
            decisionOwner: author,
            results: results,
            overrides: overrideRecords,
            riskTier: riskTier,
            ethicalFlags: [],
            consistencyScore: consistencyScore,
            complianceCount: complianceCount,
            commitSHA: provenance.headSHA,
            runScope: runScope,
            gateBuild: GateBuild(commit: BuildStamp.gitCommit, buildDate: BuildStamp.buildDate),
            identityKind: identityKind
        )

        let calibrations = CalibrationClassifier.classify(
            overrides: allOverrides,
            decisionOwner: author,
            practitioner: author,
            riskTier: riskTier,
            timestamp: runTimestamp
        )

        // Record the work-event that produced this run's metrics. Idempotent
        // by (day, SHA). Best-effort: never fail the gate on a write issue.
        let workEvent = WorkEvent(
            date: runTimestamp,
            commitSHA: provenance.headSHA,
            commitSubjects: provenance.subjects,
            changelogDelta: provenance.changelogDelta,
            sessionSummary: provenance.sessionSummary
        )
        do {
            try await writer.writeWorkEvent(workEvent, to: corpus)
        } catch {
            logger.warning("Work-log write failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            try await writer.write(metadata: metadata, calibrations: calibrations, to: corpus)

            if configuration.complexity.emitToCorpus, checkerRan("complexity", in: runScope) {
                let analyzer = ComplexityAnalyzer()
                let records = analyzer.scanProject(configuration: configuration)
                let report = ComplexityTelemetryEmitter.buildReport(
                    from: records,
                    projectID: projectID,
                    timestamp: metadata.timestamp,
                    threshold: configuration.complexity.cognitiveThreshold
                )
                try await writer.writeComplexityReport(report, to: corpus)
            }

            if configuration.legibility.emitToCorpus, checkerRan("legibility", in: runScope) {
                let orientationReport = await LegibilityAnalyzer().orientationReport(
                    configuration: configuration,
                    timestamp: metadata.timestamp,
                    projectID: projectID
                )
                try await writer.writeOrientationReport(orientationReport, to: corpus)
            }

            if verbose {
                print("\n[ijs] Telemetry written to \(corpus.projectDirectory)")
                if !calibrations.isEmpty {
                    print("[ijs] \(calibrations.count) calibration(s) auto-generated")
                }
            }
        } catch {
            logger.warning("Telemetry write failed: \(error.localizedDescription, privacy: .public)")
            if verbose {
                print("\n[ijs] Telemetry write failed: \(error.localizedDescription)")
            }
        }
    }

    /// True when the named checker was part of this run's scope.
    private static func checkerRan(_ checkerID: String, in scope: RunScope) -> Bool {
        switch scope {
        case .full:
            return true
        case .subset(let checkers):
            return checkers.contains(checkerID)
        }
    }
}
