
import ArgumentParser
import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore
import SafetyAuditor
import BuildChecker
import TestRunner
import DocLinter
import DocCoverageChecker
import DiskCleaner
import UnreachableCodeAuditor
import RecursionAuditor
import ConcurrencyAuditor
import PointerEscapeAuditor
import MemoryBuilder
import AccessibilityAuditor
import StatusAuditor
import SwiftVersionChecker
import LoggingAuditor
import TestQualityAuditor
import ContextAuditor
import DependencyAuditor
import SubmoduleAuditor
import ReleaseReadinessAuditor
import FloatingPointSafetyAuditor
import StochasticDeterminismAuditor
import TemporalDeterminismAuditor
import MCPReadinessAuditor
import ProcessSafetyAuditor
import MemoryLifecycleGuard
import ComplexityAnalyzer
import LegibilityAnalyzer
import HIGAuditor
import AppIntentsAuditor
import XcodeBuildChecker
import ConsistencyChecker
import GatePlugins
import IdiomAuditor
import SmellPack
import DuplicationAuditor
import KeychainSecretsChecker
import PrivacyManifestChecker
import ControlMapping
import IJSSensor
import IJSAggregator

/// A text output stream that writes to stdout.
struct StandardOutputStream: TextOutputStream {
    mutating func write(_ string: String) {
        print(string, terminator: "")
    }
}

/// Quality Gate CLI - Automated quality checks for Swift projects.
@main
struct QualityGateCLI: AsyncParsableCommand {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "QualityGateCLI")

    static let configuration = CommandConfiguration(
        commandName: "quality-gate",
        abstract: "Run automated quality checks on a Swift project.",
        version: "2.0.1",
        subcommands: [Calibrate.self, TelemetryPush.self, GeneratePulse.self, GenerateNarrative.self, Dashboard.self, GenerateManifest.self, MigrateCorpusIdentity.self, Doctor.self, BuildInfo.self, ConfigCommand.self, Orient.self, CICommand.self, Adopt.self, ImportSwiftLint.self, ReVerify.self, CorpusdToken.self, Compliance.self]
    )

    @Option(name: .shortAndLong, help: "Output format (terminal, json, sarif, xcode)")
    var format: String = "terminal"

    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    @Option(name: .long, parsing: .upToNextOption, help: "Specific checkers to run (use 'all' for every checker)")
    var check: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Checkers to skip when using --check all")
    var exclude: [String] = []

    @Flag(name: .long, help: "Continue running checks even if one fails")
    var continueOnFailure: Bool = false

    @Flag(name: .long, help: "Treat warnings as failures (exit code 1)")
    var strict: Bool = false

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    @Flag(name: .long, help: "Drive `xcodebuild build` automatically when the unreachable checker can't find a fresh DerivedData index store for an Xcode project / workspace.")
    var autoBuildXcode: Bool = false

    @Flag(name: .long, help: "Include slow checkers (xcode-build) that are skipped by default")
    var full: Bool = false

    @Flag(name: .long, help: "Apply auto-fixes for checkers that support FixableChecker protocol")
    var fix: Bool = false

    @Flag(name: .long, help: "Show what --fix would change without applying (requires --fix)")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Generate initial status documents from actual project state (use with --check status)")
    var bootstrap: Bool = false

    @Flag(name: .long, help: "Disable the incremental result cache (re-run every checker from scratch)")
    var noCache: Bool = false

    @Flag(name: .long, help: "Never compile a project to produce an index store; index-backed checkers reuse an existing store or degrade to AST-only. Use for fast portfolio sweeps that must not build.")
    var noIndexBuild: Bool = false

    @Flag(name: .long, help: "Force foreign mode: the repo is analyzed read-only, every write redirects to the overlay (~/.quality-gate/overlays/<identity>/), and --fix is refused.")
    var foreign: Bool = false

    @Flag(name: .long, help: "Force resident mode even when the repo has no config and an overlay exists.")
    var resident: Bool = false

    @Flag(name: .customLong("advisory-all"), help: "Trial mode: run everything, downgrade every error/warning to a note, exit 0. Recorded as gateMode: advisory — never counts as a green gate.")
    var advisoryAll: Bool = false

    @Option(name: .long, help: "Override cognitive complexity threshold (used with --check complexity)")
    var threshold: Int?

    @Option(name: .customLong("telemetry-corpus-path"), help: "Override corpus path for telemetry (useful for CI)")
    var telemetryCorpusPath: String?

    @Option(name: .customLong("sarif-output"), help: "Also write a SARIF report to this path (in addition to the primary format)")
    var sarifOutput: String?

    @Option(name: .customLong("summary-output"), help: "Also write a JSON summary to this path (in addition to the primary format)")
    var summaryOutput: String?

    /// The active Swift toolchain version string, folded into the cache's gate identity so a
    /// compiler change invalidates cached results. Returns "" on failure (still a stable key).
    private static func toolchainVersion() -> String {
        // SAFETY: subprocess with hardcoded `/usr/bin/env swift --version`
        do {
            let result = try ProcessRunner.run("/usr/bin/env", arguments: ["swift", "--version"])
            guard result.exitCode == 0 else { return "" }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Self.logger.warning("Could not probe toolchain version for cache identity: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// The full checker registry (order matters for output), shared by the
    /// main run and `adopt` so a baseline is recorded by exactly the gate
    /// that will later enforce it.
    static func checkerRegistry(configuration: Configuration) -> [any QualityChecker] {
        return [
            BuildChecker(),
            TestRunner(),
            SafetyAuditor(),
            DocLinter(),
            DocCoverageChecker(),
            UnreachableCodeAuditor(),
            RecursionAuditor(),
            ConcurrencyAuditor(
                firstPartyModules: PackageManifestParser.firstPartyTargets(at: FileManager.default.currentDirectoryPath),
                allowPreconcurrencyImports: Set(configuration.concurrency.allowPreconcurrencyImports),
                justificationKeyword: configuration.concurrency.justificationKeyword,
                cancellationCheckpointStrict: configuration.concurrency.cancellationCheckpointStrict
            ),
            PointerEscapeAuditor(
                allowedEscapeFunctions: Set(configuration.pointerEscape.allowedEscapeFunctions)
            ),
            MemoryBuilder(
                guidelinesPath: configuration.memoryBuilder.guidelinesPath
            ),
            AccessibilityAuditor(),
            StatusAuditor(),
            SwiftVersionChecker(),
            LoggingAuditor(config: configuration.logging),
            TestQualityAuditor(),
            ContextAuditor(),
            DependencyAuditor(),
            SubmoduleAuditor(),
            ReleaseReadinessAuditor(),
            FloatingPointSafetyAuditor(),
            StochasticDeterminismAuditor(),
            TemporalDeterminismAuditor(),
            MemoryLifecycleGuard(),
            MCPReadinessAuditor(),
            ProcessSafetyAuditor(),
            KeychainSecretsChecker(config: configuration.keychainSecrets),
            PrivacyManifestChecker(config: configuration.privacyManifest),
            ControlMappingValidator(),
            ComplexityAnalyzer(),
            LegibilityAnalyzer(),
            HIGAuditor(),
            AppIntentsAuditor(),
            ConsistencyChecker(),
            XcodeBuildChecker(),
            DiskCleaner(),
            // Major-points parity (Phase 4c): advisory posture — notes by
            // default, config-tunable up; the gate blocks on correctness.
            IdiomAuditor(config: configuration.idiom),
            SmellPack(config: configuration.smells),
            DuplicationAuditor(config: configuration.duplication)

            // Tier-2 plugins (Phase 4b): advisory by default, origin-tagged,
            // failure is a finding — never a crash.
        ] + configuration.plugins.map { PluginChecker(plugin: $0) as any QualityChecker }
        // Tier-1 custom rules (Phase 4b): present only when declared — the
        // user's own policy, gating by each rule's declared severity.
        + (configuration.customRules.isEmpty ? [] : [CustomRulesChecker()])
    }

    func run() async throws {
        // Propagate --no-index-build to StoreLocator (which lives in a lower module and reads
        // this env var) so index-backed checkers never trigger a compile — they reuse an
        // existing store or degrade to AST-only. Set before any checker runs.
        if noIndexBuild {
            setenv("QG_NO_INDEX_BUILD", "1", 1)
        }

        if let skipRef = ProcessInfo.processInfo.environment["QG_SKIP"] {
            guard skipRef != "1", skipRef != "true",
                  skipRef.contains("/") || skipRef.contains("#") else {
                print("ERROR: QG_SKIP requires an issue URL or reference (e.g. QG_SKIP=https://github.com/org/repo/issues/42)")
                print("Bare QG_SKIP=1 is not allowed — every skip must be traceable.")
                throw ExitCode.failure
            }
            print("⚠ Quality gate SKIPPED — issue: \(skipRef)")
            try await recordSkip(issueReference: skipRef)
            return
        }

        // Load configuration through the layered resolver (Phase 1):
        // repo `.quality-gate.yml` → overlay → user-global → defaults,
        // first hit per section. With no overlay or global config on disk
        // this is byte-for-byte the old repo-only load.
        var configuration: Configuration
        var configProvenance: ConfigProvenance?
        var overlayDirectory: URL?
        var hasRepoConfig = true
        do {
            let resolution = try LayeredConfig.resolve(repoConfigPath: config)
            configuration = resolution.configuration
            configProvenance = resolution.provenance
            hasRepoConfig = resolution.provenance.repoConfigPath != nil
            // Auto-detection requires a real overlay config; forcing foreign
            // only requires somewhere to redirect writes to.
            if resolution.hasOverlayConfig || foreign {
                overlayDirectory = resolution.overlayDirectory
            }
            if verbose, resolution.provenance.overlayConfigPath != nil
                || resolution.provenance.userGlobalConfigPath != nil {
                print("Config layers in effect (run `quality-gate config` for detail):")
                print(resolution.provenance.renderTable())
            }
        } catch {
            Self.logger.warning("Failed to load configuration from \(self.config, privacy: .public): \(error.localizedDescription, privacy: .public). Using defaults.")
            configuration = Configuration()
            if verbose {
                print("Warning: failed to load \(config): \(error). Using defaults.")
            }
        }
        // CLI flag overrides config (v5).
        // CLI flags override config through one testable seam (Phase 0.2):
        // ConfigurationOverrideIsolationTests proves each override touches
        // exactly its own field.
        configuration = configuration.applying(CLIOverrides(
            autoBuildXcode: autoBuildXcode,
            threshold: threshold,
            telemetryCorpusPath: telemetryCorpusPath
        ))

        // Run environment (Phase 1): resident behaves as always; foreign
        // redirects every write into the overlay and enforces read-only
        // analysis structurally (WriteGuard + Maintainer's Promise).
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let runEnvironment = RunEnvironment.detect(
            repoRoot: repoRoot,
            hasRepoConfig: hasRepoConfig,
            overlayDirectory: overlayDirectory,
            forceForeign: foreign,
            forceResident: resident)
        if runEnvironment.isForeign {
            if fix {
                print("ERROR: --fix is refused in foreign mode — the findings are yours, the code isn't.")
                throw ExitCode(1)
            }
            // Backstop for writers below the CLI (same pattern as QG_NO_INDEX_BUILD).
            setenv(WriteGuard.environmentVariable, runEnvironment.repoRoot.path, 1)
            if configuration.legibility.artifactPath == nil {
                configuration.legibility.artifactPath =
                    runEnvironment.artifactsRoot.appendingPathComponent("legibility").path
            }
            print("🔒 Foreign mode: \(runEnvironment.repoRoot.path) is analyzed read-only; writes → \(runEnvironment.artifactsRoot.deletingLastPathComponent().path)")
        }

        // Stale-binary self-check (0.6): a stale installed binary silently
        // runs old rules. Repos ratchet minimumGateVersion when they depend
        // on new ones; the hook (--strict) then refuses to run stale.
        switch GateVersionCheck.check(minimum: configuration.minimumGateVersion, buildDate: BuildStamp.buildDate) {
        case .noPin, .satisfied:
            break
        case .stale(let installed, let required):
            print("⚠ Stale gate binary: built \(installed), but this repo requires minimumGateVersion \(required).")
            print("  Rebuild and reinstall the gate (make install) before trusting results.")
            if strict {
                print("ERROR: refusing to run a stale gate under --strict.")
                throw ExitCode(1)
            }
        case .unparseablePin(let pin):
            print("⚠ minimumGateVersion '\(pin)' is not a date (YYYY-MM-DD or ISO8601) — pin ignored.")
        }

        // Create override processor from configuration.
        let overrideProcessor = OverrideProcessor(
            overrides: configuration.overrides,
            vendorPaths: configuration.vendorPaths
        )

        // Build the full checker registry (order matters for output)
        let allCheckers = Self.checkerRegistry(configuration: configuration)

        // Determine effective checkers: --check all | --check X Y | config | defaults.
        // Destructive maintenance checkers (disk-clean) are opt-in even under "all".
        let effectiveCheckers = CheckerSelection.resolve(
            requested: check,
            excluded: exclude,
            configuredEnabled: configuration.enabledCheckers,
            full: full,
            allIDs: allCheckers.map(\.id)
        )

        let checkersToRun = allCheckers.filter { checker in
            effectiveCheckers.contains(checker.id)
        }

        if checkersToRun.isEmpty {
            print("No checkers enabled. Nothing to do.")
            return
        }

        // Create reporter
        let outputFormat: OutputFormat
        switch format.lowercased() {
        case "json":
            outputFormat = .json
        case "sarif":
            outputFormat = .sarif
        case "xcode":
            outputFormat = .xcode
        default:
            outputFormat = .terminal
        }
        let reporter = ReporterFactory.create(for: outputFormat)

        if verbose {
            print("Running \(checkersToRun.count) checkers concurrently...")
        }

        // Incremental result cache: checkers that opt in via `cacheInputs` skip re-running when
        // their inputs are byte-identical to a prior run. The gate identity (binary + toolchain)
        // is folded into every key, so a gate rebuild or compiler change invalidates all entries.
        let gateHash = CheckerFingerprint.gateIdentityHash(
            executablePath: CheckerFingerprint.runningExecutablePath(),
            toolchainVersion: Self.toolchainVersion()
        )
        // Cache location resolves through the run environment: the repo's
        // .build when resident, the overlay's cache dir when foreign.
        let resultCache = ResultCache(
            directory: runEnvironment.cacheRoot.appendingPathComponent("quality-gate-cache"))

        // Run checkers concurrently (bounded by core count), preserving checker order.
        // Overrides are applied via `transform` so pass/fail — and the continueOnFailure
        // early-exit — match the previous sequential behavior exactly.
        //
        // `QG_BENCH_CONCURRENCY` overrides the bound (diagnostic/benchmark only): set to 1
        // to force the pre-parallelization sequential baseline, or any N to cap concurrency.
        // Unset → the default (active processor count).
        let benchConcurrency = ProcessInfo.processInfo.environment["QG_BENCH_CONCURRENCY"].flatMap(Int.init)
        let runner = benchConcurrency.map(CheckerRunner.init(maxConcurrency:)) ?? CheckerRunner()
        var allResults = await runner.run(
            checkers: checkersToRun,
            configuration: configuration,
            strict: strict,
            continueOnFailure: continueOnFailure,
            cache: resultCache,
            gateHash: gateHash,
            useCache: !noCache,
            transform: { overrideProcessor.apply(to: $0) },
            onError: { checkerID, error in
                Self.logger.error("Checker '\(checkerID, privacy: .public)' threw an error: \(error.localizedDescription, privacy: .public)")
            }
        )
        // Decaying baseline (Phase 4c §3): recorded debts become notes with
        // their expiry visible; expired debts return as re-verify warnings;
        // new findings gate. Applied before trial mode so both transforms
        // see honest inputs. A ledger read failure is loud, never silent.
        let baselinePath = ".quality-gate-baseline.json"
        var baselineSnapshot: BaselineSnapshot?
        if FileManager.default.fileExists(atPath: baselinePath) { // SAFETY: read-only check at repo root
            do {
                let ledger = try BaselineLedger.load(from: baselinePath)
                let applied = BaselineLedger.apply(ledger: ledger, to: allResults, now: Date())
                allResults = applied.results
                baselineSnapshot = BaselineSnapshot(
                    baselined: applied.summary.baselined,
                    expired: applied.summary.expired,
                    newFindings: applied.summary.newFindings)
                print("ℹ️  Baseline: \(applied.summary.baselined) debt(s) covered, \(applied.summary.expired) EXPIRED (re-verify), \(applied.summary.newFindings) new finding(s) gating.")
            } catch {
                Self.logger.error("Baseline ledger unreadable at \(baselinePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                print("⚠ Baseline ledger unreadable (\(error.localizedDescription)) — running WITHOUT baseline coverage.")
            }
        }

        // Trial mode (Phase 4 §3): the survey transform — findings visible,
        // nothing gates. Applied before reporting so terminal/SARIF/telemetry
        // all see the same downgraded truth.
        if advisoryAll {
            allResults = AdvisoryDowngrade.apply(to: allResults)
            print("ℹ️  Trial mode (--advisory-all): findings reported as notes; nothing gates this run.")
        }
        let hasFailure = allResults.contains { result in
            if result.status == .failed { return true }
            if strict && result.status == .warning { return true }
            return false
        }

        // Handle --bootstrap: generate initial status documents
        if bootstrap {
            let currentDir = FileManager.default.currentDirectoryPath
            let guidelinesDir = (currentDir as NSString).appendingPathComponent(
                configuration.status.guidelinesPath
            )
            let masterPlanDir = (guidelinesDir as NSString).appendingPathComponent("00_CORE_RULES")
            let masterPlanPath = (masterPlanDir as NSString).appendingPathComponent("00_MASTER_PLAN.md")

            let content = StatusBootstrapper.generate(
                projectRoot: currentDir,
                configuration: configuration
            )

            if dryRun {
                print("\n[status] Would generate Master Plan at: \(masterPlanPath)\n")
                print(content)
                print("No files modified (dry-run mode).")
            } else {
                try FileManager.default.createDirectory( // SAFETY: CLI tool creates local project directory
                    atPath: masterPlanDir,
                    withIntermediateDirectories: true
                )
                try content.write(toFile: masterPlanPath, atomically: true, encoding: .utf8)
                print("\n[status] Generated Master Plan at: \(masterPlanPath)")
                print("  Review and add project-specific prose where marked <!-- TODO -->")
            }
            return
        }

        // Handle --fix: apply auto-fixes for FixableChecker conformers
        if fix {
            for result in allResults where result.status == .failed {
                let checker = checkersToRun.first { $0.id == result.checkerId }
                guard let fixable = checker as? (any FixableChecker) else {
                    continue
                }

                if dryRun {
                    print("\n[dry-run] \(fixable.name) would apply fixes:")
                    print("  \(fixable.fixDescription)")
                    for diag in result.diagnostics {
                        if let fix = diag.suggestedFix, let file = diag.filePath {
                            let lineInfo = diag.lineNumber.map { ":\($0)" } ?? ""
                            print("    \(file)\(lineInfo): \(fix)")
                        }
                    }
                } else {
                    print("\n[\(fixable.id)] Applying fixes...")
                    let fixResult = try await fixable.fix(
                        diagnostics: result.diagnostics,
                        configuration: configuration
                    )

                    for mod in fixResult.modifications {
                        let backup = mod.backupPath.map { " (backup: \($0))" } ?? ""
                        print("  ✓ \(mod.filePath) — \(mod.description)\(backup)")
                    }

                    if !fixResult.unfixed.isEmpty {
                        print("  ℹ  \(fixResult.unfixed.count) diagnostic(s) require manual intervention")
                    }
                }
            }
        }

        // Output results
        var outputStream = StandardOutputStream()
        try reporter.report(allResults, to: &outputStream)

        // Machine-readable artifacts alongside the primary format (Phase 2:
        // `quality-gate ci` turns these on; any caller may). Best-effort —
        // an artifact write failure is logged, never fails the gate itself.
        writeArtifactReport(format: .sarif, to: sarifOutput, results: allResults)
        writeArtifactReport(format: .json, to: summaryOutput, results: allResults)

        // One post-run telemetry step for every configured invocation (0.1):
        // full runs and --check subsets both record, tagged with their scope
        // so gate statistics stay honest downstream.
        //
        // Foreign runs are silent by default (Phase 1 §2b): nothing about an
        // analyzed project is recorded anywhere unless the *overlay itself*
        // configured the corpus — a repo- or user-global corpus path never
        // captures a repo that isn't yours as a side effect.
        let runScope: RunScope = (check.isEmpty || check.contains("all"))
            ? .full
            : .subset(checkers: effectiveCheckers)
        if !runEnvironment.isForeign || configProvenance?.origin(of: "consistency") == .overlay {
            await TelemetryEmission.emit(
                configuration: configuration,
                results: allResults,
                runScope: runScope,
                identityKind: runEnvironment.isForeign ? .foreign : .resident,
                gateMode: advisoryAll ? .advisory : .standard,
                baseline: baselineSnapshot,
                verbose: verbose
            )
        } else if verbose {
            print("\n[ijs] Foreign mode: telemetry silent (corpus not configured by the overlay)")
        }

        // Suggest --fix when status fails and --fix wasn't used
        if hasFailure && !fix {
            let hasFixable = allResults.contains { result in
                result.status == .failed
                    && checkersToRun.contains { $0.id == result.checkerId && $0 is any FixableChecker }
            }
            if hasFixable {
                print("\n💡 Run with --fix --dry-run to preview auto-fixes.")
            }
        }

        // Exit with appropriate code
        if hasFailure && !fix {
            throw ExitCode(1)
        }
    }

    /// Renders results in `format` and writes them to `path`, creating parent
    /// directories. Best-effort: a failure is logged and printed, never
    /// thrown — a missing artifact must not change the gate's verdict.
    private func writeArtifactReport(format: OutputFormat, to path: String?, results: [CheckResult]) {
        guard let path else { return }
        var rendered = ""
        do {
            try WriteGuard.validate(path: path)
            try ReporterFactory.create(for: format).report(results, to: &rendered)
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true) // SAFETY: caller-requested artifact directory
            try rendered.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.warning("Failed to write \(format.rawValue, privacy: .public) artifact to \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            print("⚠ Could not write \(format.rawValue) artifact to \(path): \(error.localizedDescription)")
        }
    }

    private func recordSkip(issueReference: String) async throws {
        var configuration: Configuration
        do {
            configuration = try Configuration.load(from: config)
        } catch {
            Self.logger.warning("Failed to load configuration for skip recording: \(error.localizedDescription, privacy: .public). Using defaults.")
            configuration = Configuration()
        }

        guard let corpusPath = configuration.consistency.corpusPath else {
            print("[ijs] No corpus configured — skip not recorded.")
            return
        }

        let projectID = EffectiveProjectID.resolve(consistency: configuration.consistency)
        let isCI = ProcessInfo.processInfo.environment["CI"] != nil

        let record = SkipRecord(
            projectID: projectID,
            timestamp: Date(),
            issueReference: issueReference,
            author: ProcessInfo.processInfo.environment["USER"] ?? "unknown",
            environment: isCI ? .ci : .local
        )

        do {
            let corpus = CorpusPath(basePath: corpusPath, projectID: projectID)
            // Skips are judgments — they ride the fail-open spool (3a §8).
            let writer = SpoolingCorpusTransport(
                upstream: DirectCorpusTransport(),
                spoolDirectory: OverlayStore.standard().root
                    .appendingPathComponent("spool", isDirectory: true))
            try await writer.writeSkip(record, to: corpus)
            print("[ijs] Skip recorded to corpus for \(projectID)")
        } catch {
            Self.logger.warning("Skip recording failed for project \(projectID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            print("[ijs] Skip recording failed: \(error.localizedDescription)")
        }
    }
}
