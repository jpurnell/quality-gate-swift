import Foundation
#if canImport(os)
import os
#endif
import ComplexityAnalyzer
import GateCI
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
    /// `baseline` carries the applied ledger's counts (Phase 4c §3) so the
    /// dashboard can render debt as a burn-down; nil when no ledger ran.
    /// `truncation` records an early stop (Change C): without it a truncated
    /// run's record is indistinguishable from a clean scoped run, and the
    /// corpus accumulates records that cannot answer "did this checker run?".
    static func emit(
        configuration: Configuration,
        results: [CheckResult],
        runScope: RunScope,
        identityKind: IdentityKind = .resident,
        gateMode: GateMode = .standard,
        baseline: BaselineSnapshot? = nil,
        truncation: RunTruncation? = nil,
        cache: ResultCache? = nil,
        gateHash: String = "",
        digests: FileDigestCache? = nil,
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
        let author = configuration.ijs.resolvedOwner()
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
        let gatedProjectDir = configuration.resolvedProjectRoot.path
        let corpus = CorpusPath(basePath: corpusPath, projectID: projectID)
        // Phase 3a §8: enforcement-path writes ride the fail-open transport.
        // A down/unreachable corpus spools to ~/.quality-gate/spool/ and each
        // emission starts by draining whatever a prior outage left behind.
        let writer = SpoolingCorpusTransport(
            upstream: DirectCorpusTransport(),
            spoolDirectory: OverlayStore.standard().root
                .appendingPathComponent("spool", isDirectory: true))
        do {
            let drained = try await writer.drainSpool()
            if drained > 0 {
                print("[ijs] Drained \(drained) spooled write(s) from a previous outage.")
            }
        } catch {
            logger.warning("Spool drain failed: \(error.localizedDescription, privacy: .public)")
        }
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
            identityKind: identityKind,
            // Verified identity when a CI provider attests the run (Phase 2);
            // host attribution otherwise, so the second-writer tripwire can
            // tell machines apart.
            ciIdentity: CIIdentityProbe.detect(environment: ProcessInfo.processInfo.environment),
            host: ProcessInfo.processInfo.hostName,
            gateMode: gateMode,
            baseline: baseline,
            truncation: truncation.map {
                TruncationRecord(stoppedAt: $0.stoppedAt, unreached: $0.unreached)
            }
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
                let records = cachedComplexityRecords(
                    configuration: configuration, cache: cache, gateHash: gateHash, digests: digests)
                let report = ComplexityTelemetryEmitter.buildReport(
                    from: records,
                    projectID: projectID,
                    timestamp: metadata.timestamp,
                    threshold: configuration.complexity.cognitiveThreshold
                )
                try await writer.writeComplexityReport(report, to: corpus)
            }

            if configuration.legibility.emitToCorpus, checkerRan("legibility", in: runScope) {
                let orientationReport = await cachedOrientationReport(
                    configuration: configuration,
                    timestamp: metadata.timestamp,
                    projectID: projectID,
                    cache: cache,
                    gateHash: gateHash,
                    digests: digests
                )
                try await writer.writeOrientationReport(orientationReport, to: corpus)
            }

            if verbose {
                print("\n[ijs] Telemetry written to \(corpus.projectDirectory)")
                if !calibrations.isEmpty {
                    print("[ijs] \(calibrations.count) calibration(s) auto-generated")
                }
            }

            // Second-writer tripwire (Phase 2 §4b): a standing warning on
            // every run once a second distinct person appears in the window.
            // Warning-only by design — the transition is surfaced, never
            // blocked. Failure to census must never fail the gate.
            do {
                let windowStart = runTimestamp.addingTimeInterval(
                    -Double(WriterCensus.defaultWindowDays) * 86_400)
                let recent = try await writer.readMetadata(
                    from: corpus, startDate: windowStart, endDate: runTimestamp)
                let census = WriterCensus.census(of: recent, now: runTimestamp)
                if let warning = census.standingWarning {
                    print("\n\(warning)")
                }
            } catch {
                logger.warning("Second-writer census failed: \(error.localizedDescription, privacy: .public)")
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

    /// The complexity sidecar's records, from the artifact cache when the source tree is
    /// unchanged, else from a fresh scan.
    ///
    /// The scan re-parses every file under `Sources/` with SwiftSyntax (~1.5s warm) even
    /// when the `complexity` checker itself was a cache hit, because it runs here — after
    /// the runner — not inside `check()`. Keyed by the checker's own declared input set,
    /// so record reuse is exactly as safe as result reuse.
    private static func cachedComplexityRecords(
        configuration: Configuration,
        cache: ResultCache?,
        gateHash: String,
        digests: FileDigestCache?
    ) -> [FunctionComplexityRecord] {
        let analyzer = ComplexityAnalyzer()
        guard let cache, let inputs = analyzer.cacheInputs(configuration: configuration) else {
            return analyzer.scanProject(configuration: configuration)
        }
        let fingerprint = CheckerFingerprint.compute(
            checkerId: "telemetry-complexity", inputs: inputs, gateHash: gateHash, digests: digests)
        if let cached = cache.loadArtifact(
            [FunctionComplexityRecord].self, artifactId: "telemetry-complexity", fingerprint: fingerprint) {
            return cached
        }
        let records = analyzer.scanProject(configuration: configuration)
        cache.storeArtifact(records, artifactId: "telemetry-complexity", fingerprint: fingerprint)
        return records
    }

    /// The orientation sidecar's report, re-stamped from the artifact cache when its
    /// inputs are unchanged, else from a fresh analysis.
    ///
    /// The fresh path re-walks the module graph and index store (~4.3s warm). Inputs are
    /// the `legibility` checker's own declared set plus the two documents orientation
    /// reads that no source walk covers: the README lead and the Master Plan mission.
    /// On a hit, the cached cards are re-issued under the current run's timestamp and
    /// project id — the analysis is a pure function of the inputs; the stamp is not.
    private static func cachedOrientationReport(
        configuration: Configuration,
        timestamp: Date,
        projectID: String,
        cache: ResultCache?,
        gateHash: String,
        digests: FileDigestCache?
    ) async -> OrientationReport {
        let analyzer = LegibilityAnalyzer()
        guard let cache, var inputs = analyzer.cacheInputs(configuration: configuration) else {
            return await analyzer.orientationReport(
                configuration: configuration, timestamp: timestamp, projectID: projectID)
        }
        let root = configuration.resolvedProjectRoot.path
        inputs.files.append((root as NSString).appendingPathComponent("README.md"))
        let plan = (configuration.status.guidelinesPath as NSString)
            .appendingPathComponent(configuration.status.masterPlanPath)
        inputs.files.append((root as NSString).appendingPathComponent(plan))

        let fingerprint = CheckerFingerprint.compute(
            checkerId: "telemetry-legibility", inputs: inputs, gateHash: gateHash, digests: digests)
        if let cached = cache.loadArtifact(
            OrientationReport.self, artifactId: "telemetry-legibility", fingerprint: fingerprint) {
            return OrientationReport(
                projectID: projectID,
                timestamp: timestamp,
                cards: cached.cards,
                packageDependsOn: cached.packageDependsOn,
                packageSummary: cached.packageSummary
            )
        }
        let report = await analyzer.orientationReport(
            configuration: configuration, timestamp: timestamp, projectID: projectID)
        cache.storeArtifact(report, artifactId: "telemetry-legibility", fingerprint: fingerprint)
        return report
    }
}
