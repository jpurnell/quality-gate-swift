
import ArgumentParser
import Foundation
import ProcessKernel
import QualityGateLogging
import QualityGateCore
import IndexStoreInfra
import SafetyAuditor
import BuildChecker
import TestRunner
import DocLinter
import DocCodeAuditor
import DocCoverageChecker
import DocGeneratedAuditor
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
import BoundedIOAuditor
import GPUSafetyAuditor
import LivenessAuditor
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
import CorpusKit
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
        version: "3.4.0",
        subcommands: [Calibrate.self, TelemetryPush.self, GeneratePulse.self, GenerateNarrative.self, Dashboard.self, GenerateManifest.self, MigrateCorpusIdentity.self, Doctor.self, BuildInfo.self, ConfigCommand.self, Orient.self, CICommand.self, Adopt.self, ImportSwiftLint.self, ReVerify.self, CorpusdToken.self, Compliance.self, StandardsWatchCommand.self, Clean.self, Release.self]
    )

    @Option(name: .shortAndLong, help: "Output format (terminal, json, sarif, xcode)")
    var format: String = "terminal"

    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    @Option(name: .long, parsing: .upToNextOption, help: "Specific checkers to run, separated by spaces or commas (use 'all' for every checker). An id that names no checker is an error.")
    var check: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Checkers to skip, separated by spaces or commas — from a default run, from --check all, and from an explicit --check")
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

    @Flag(name: .long, help: "Enforce the release-tag invariant at full strength, as a pre-push hook does (implied when git supplies a pushed-ref list on stdin)")
    var releaseBoundary: Bool = false

    @Flag(name: .long, help: "Ignore cached results: run every checker and replace its cached entry. Does not force a clean build — it does not need to.")
    var noCache: Bool = false

    @Flag(name: .long, help: "Never compile a project to produce an index store; index-backed checkers reuse an existing store or degrade to AST-only. Use for fast portfolio sweeps that must not build.")
    var noIndexBuild: Bool = false

    @Flag(name: .long, help: "Force foreign mode: the repo is analyzed read-only, every write redirects to the overlay (~/.quality-gate/overlays/<identity>/), and --fix is refused.")
    var foreign: Bool = false

    @Option(name: .long, help: "Run a named selection: code (static analysis only — no compiler is invoked and the surveyed package's code is never executed), docs, or all. Implies --foreign: a profile run analyses read-only and redirects every write to the overlay.")
    var profile: CheckerProfile?

    @Flag(name: .long, help: "Force resident mode even when the repo has no config and an overlay exists.")
    var resident: Bool = false

    @Flag(name: .customLong("advisory-all"), help: "Trial mode: run everything, downgrade every error/warning to a note, exit 0. Recorded as gateMode: advisory — never counts as a green gate.")
    var advisoryAll: Bool = false

    @Flag(name: .customLong("include-nonhermetic"), help: "Let time-dependent and network-dependent checkers fail the gate. Off by default: a finding the commit cannot be held responsible for is reported as a note, never blocked on.")
    var includeNonHermetic: Bool = false

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
            // `ProcessKernel.ProcessRunner`, qualified: CorpusKit 1.16.0 added a public type of the
            // same name, and this file sees both. The ambiguity was invisible while `IJSSensor`
            // re-exported CorpusKit — the compiler silently picked one. Naming the module is the
            // fix; the import is explicit now, so the conflict is too.
            let result = try ProcessKernel.ProcessRunner.run("/usr/bin/env", arguments: ["swift", "--version"])
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
    /// The checkers this binary ships, in the order they run.
    ///
    /// - Parameters:
    ///   - configuration: Supplies each checker's knobs.
    ///   - pushedRefs: The refs git is about to push, when this run is a `pre-push` boundary.
    ///     Only `release-readiness` consumes it, and only there do its tag rules gate.
    static func checkerRegistry(
        configuration: Configuration, pushedRefs: [PushedRef]? = nil
    ) -> [any QualityChecker] {
        return [
            BuildChecker(),
            TestRunner(),
            SafetyAuditor(),
            DocLinter(),
            DocCodeAuditor(),
            DocRunAuditor(),
            DocClaimsAuditor(),
            DocCommentCodeAuditor(),
            DocGeneratedAuditor(),
            DocCoverageChecker(),
            UnreachableCodeAuditor(),
            RecursionAuditor(),
            ConcurrencyAuditor(
                firstPartyModules: PackageManifestParser.firstPartyTargets(at: configuration.resolvedProjectRoot.path),
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
            ReleaseReadinessAuditor(pushedRefs: pushedRefs),
            FloatingPointSafetyAuditor(),
            FallbackAuditor(),
            StochasticDeterminismAuditor(),
            TemporalDeterminismAuditor(),
            GPUSafetyAuditor(),
            MemoryLifecycleGuard(),
            MCPReadinessAuditor(),
            ProcessSafetyAuditor(),
            LivenessAuditor(),
            BoundedIOAuditor(),
            KeychainSecretsChecker(config: configuration.keychainSecrets),
            PrivacyManifestChecker(config: configuration.privacyManifest),
            ControlMappingValidator(),
            ComplexityAnalyzer(),
            LegibilityAnalyzer(),
            HIGAuditor(),
            AppIntentsAuditor(),
            ConsistencyChecker(),
            XcodeBuildChecker(),
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
            //
            // `--profile` forces it too. A profile exists to point the gate at a repository the
            // operator does not own, and such a run must leave nothing behind — so the overlay
            // is required rather than optional, and foreign mode is not a flag the caller can
            // forget. Selection and write-behaviour are different axes, and coupling them here
            // is deliberate: the failure mode of forgetting `--foreign` is writing into a
            // stranger's checkout, which is not a mistake worth preserving the orthogonality
            // for.
            if resolution.hasOverlayConfig || foreign || profile != nil {
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

        // A key the schema does not define was discarded during decoding, and a discarded
        // key is a statement the gate never heard. Reported at startup, before any checker
        // runs, because the consequence is *which checkers run at all* — BusinessMath wrote
        // `checkers:` for `enabledCheckers` and ran 35 of 42 for as long as the file
        // existed, with `recursion` among those never run.
        //
        // Advisory for one release: this is a breaking change for any repository carrying a
        // stale key, and it should break with a fix in hand rather than a wall.
        if let unknown = configuration.unknownKeys {
            FileHandle.standardError.write(Data(
                ("⚠️  configuration: " + unknown.message
                 + "\n   This is advisory in this release and will become an error.\n\n")
                    .utf8))
        }

        // Run environment (Phase 1): resident behaves as always; foreign
        // redirects every write into the overlay and enforces read-only
        // analysis structurally (WriteGuard + Maintainer's Promise).
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        // `--profile` and `--resident` are contradictory: one says "this repository is not
        // mine", the other says "write into it anyway". Refused loudly rather than resolved by
        // precedence, because whichever way precedence fell it would be silent.
        if profile != nil && resident {
            print("ERROR: --profile implies --foreign; --resident contradicts it.")
            print("A profile run analyses a repository read-only. Drop one of the two flags.")
            throw ExitCode(1)
        }
        let runEnvironment = RunEnvironment.detect(
            repoRoot: repoRoot,
            hasRepoConfig: hasRepoConfig,
            overlayDirectory: overlayDirectory,
            forceForeign: foreign || profile != nil,
            forceResident: resident)
        // The one place the resolved root enters the configuration artery. Every checker
        // downstream reads `configuration.resolvedProjectRoot` instead of the process cwd.
        configuration.projectRoot = runEnvironment.repoRoot

        // A path the gate cannot use as written stops the run here, before any checker and
        // before telemetry — which is the step that acts on `corpusPath` by creating it.
        // `corpusPath: ${ORG_JUDGEMENT_CORPUS:-}` was never expanded: two repositories grew a
        // directory with that literal name and three weeks of telemetry inside it, while
        // every run printed PASSED. Fatal rather than advisory because the run's own side
        // effect is the damage; there is no later point at which refusing still helps.
        let pathErrors = configuration.pathConfigurationErrors()
        guard pathErrors.isEmpty else {
            let lines = pathErrors.map { "❌ configuration: " + $0 }.joined(separator: "\n")
            FileHandle.standardError.write(Data((lines + "\nNothing was run.\n").utf8))
            throw ExitCode(1)
        }
        // Resolved once, after the check above, so `.rejected` cannot occur below.
        let corpusLocation = configuration.corpusLocation()
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
        // A `pre-push` hook receives the refs being pushed on stdin, and the installed hook
        // template already passes its stdin through to this process — so the boundary is
        // detected from data that is already arriving, and no repository has to change a hook
        // to gain the check. `--release-boundary` covers CI, where there is no hook at all.
        let pushedRefs = releaseBoundary ? (PushedRefs.fromStandardInput() ?? []) : PushedRefs.fromStandardInput()
        let allCheckers = Self.checkerRegistry(configuration: configuration, pushedRefs: pushedRefs)

        // Determine effective checkers: --profile | --check all | --check X Y | config |
        // defaults — resolved *and validated* before anything runs.
        //
        // `consistency` audits the run, so it cannot be *in* the run.
        //
        // It reads telemetry, and the current run's telemetry is written after every checker
        // completes — so as a checker in the sweep it could only ever see the previous run,
        // and reported that run's findings inside a run whose verdict it appeared to describe.
        // It is now a post-run stage over the in-memory results (below, after `runner.run`).
        // `--check consistency` still selects it; what changed is when it runs.
        // `--profile` supplies the base selection; `--check` and `--exclude` compose on top, so
        // `--profile code --exclude complexity` means what it looks like. The profile filters
        // on what each checker *declares* — see `CheckerKind` and `CheckerEffect` — so it
        // cannot drift from the registry the way a list of ids beside it would.
        //
        // A selection the gate cannot honour is an error, not a no-op. `--check a,b` used to
        // arrive as the single id "a,b", match nothing, print "No checkers enabled. Nothing
        // to do." and exit 0; the same path swallowed a typo and dropped one bad id from a
        // good list. A run that examined nothing has not passed.
        let selection: CheckerSelection.Selection
        do {
            selection = try CheckerSelection.select(
                CheckerSelection.Request(
                    requested: check,
                    excluded: exclude,
                    configuredEnabled: configuration.enabledCheckers,
                    configuredExcluded: configuration.excludedCheckers,
                    configuredIncluded: configuration.includedCheckers,
                    full: full,
                    profileBase: profile.map { $0.checkerIDs(from: allCheckers) }),
                allIDs: allCheckers.map(\.id))
        } catch {
            if case .retired = error {
                // `disk-clean` was a checker until cleanup moved off the QualityChecker
                // protocol. Name the replacement rather than letting an old invocation look
                // like a no-op.
                print(error.message)
                print("Cleanup mutates the tree, so it is a subcommand rather than a check.")
            } else {
                FileHandle.standardError.write(Data((error.message + "\n").utf8))
            }
            throw ExitCode(error.exitCode)
        }
        for notice in selection.notices {
            FileHandle.standardError.write(Data(("ℹ️  " + notice + "\n").utf8))
        }
        let effectiveCheckers = selection.ids

        // `consistency` alone is a legitimate invocation — it is not in `checkersToRun`, so
        // an empty sweep with it selected is a consistency-only run, not an empty one.
        let consistencySelected = effectiveCheckers.contains(ConsistencyChecker().id)
        let checkersToRun = allCheckers.filter { checker in
            effectiveCheckers.contains(checker.id) && checker.id != ConsistencyChecker().id
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
        // One digest map for the whole process — the runner's ~41 fingerprints and the
        // telemetry sidecars hash each input file exactly once between them.
        let digestCache = FileDigestCache()

        // Run checkers concurrently (bounded by core count), preserving checker order.
        // Overrides are applied via `transform` so pass/fail — and the continueOnFailure
        // early-exit — match the previous sequential behavior exactly.
        //
        // `QG_BENCH_CONCURRENCY` overrides the bound (diagnostic/benchmark only): set to 1
        // to force the pre-parallelization sequential baseline, or any N to cap concurrency.
        // Unset → the default (active processor count).
        let benchConcurrency = ProcessInfo.processInfo.environment["QG_BENCH_CONCURRENCY"].flatMap(Int.init)
        let runner = benchConcurrency.map(CheckerRunner.init(maxConcurrency:)) ?? CheckerRunner()

        // Loaded *before* the run, because the transform below needs it. A ledger read failure
        // is loud and then proceeds without coverage — the same behaviour as before, moved
        // earlier. One `now` for the whole run, so a long run cannot expire a debt halfway
        // through and report two different dispositions for the same record.
        let baselinePath = ".quality-gate-baseline.json"
        let baselineNow = Date()
        // Bound once rather than assigned into: the transform below is `@Sendable`, and a
        // captured `var` is not.
        let baselineLedger: BaselineLedger? = {
            guard FileManager.default.fileExists(atPath: baselinePath) else { return nil } // SAFETY: read-only check at repo root
            do {
                return try BaselineLedger.load(from: baselinePath)
            } catch {
                Self.logger.error("Baseline ledger unreadable at \(baselinePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                print("⚠ Baseline ledger unreadable (\(error.localizedDescription)) — running WITHOUT baseline coverage.")
                return nil
            }
        }()
        let runOutcome = await runner.run(
            checkers: checkersToRun,
            configuration: configuration,
            strict: strict,
            continueOnFailure: continueOnFailure,
            cache: resultCache,
            gateHash: gateHash,
            useCache: !noCache,
            digests: digestCache,
            includeNonHermetic: includeNonHermetic,
            // The baseline goes through the same hook as overrides, and for the same reason:
            // this is applied *before* the early-exit decision. Applying it after the run (as
            // this did until the ledger was split into a per-result transform) meant the
            // checker holding baselined debt still failed during the run and truncated it —
            // every checker ordered after it never ran — and the ledger then rewrote that
            // checker's verdict to `.passed`, so the run reported success over an unexamined
            // majority. `adopt` promised a green gate on day one and charged the rest of the
            // run for it.
            transform: { result in
                let afterOverrides = overrideProcessor.apply(to: result)
                guard let ledger = baselineLedger else { return afterOverrides }
                return ledger.applying(to: afterOverrides, now: baselineNow)
            },
            onError: { checkerID, error in
                Self.logger.error("Checker '\(checkerID, privacy: .public)' threw an error: \(error.localizedDescription, privacy: .public)")
            }
        )
        var allResults = runOutcome.results

        // The reporter is created *after* the run so the summary can carry the run's
        // truncation. The registry, not the selection, is the denominator: a narrowed
        // run is self-reporting rather than requiring someone to already suspect it —
        // and a truncated run must never read as a narrowed one.
        let reporter = ReporterFactory.create(
            for: outputFormat,
            rosterSize: Self.checkerRegistry(configuration: configuration).count,
            truncation: runOutcome.truncation,
            strict: strict)

        // The post-run stage. `consistency` audits the results above rather than the newest
        // telemetry on disk, which is the previous run — appended before the reporter and
        // before `TelemetryEmission.emit`, which reads this result to embed the score.
        if consistencySelected {
            do {
                // `--check consistency` on its own has no current run to audit — the sweep is
                // empty, and auditing zero results would score a vacuous 1.00 while printing
                // what a real pass prints. That is the failure this project keeps finding, so
                // isolation takes the fallback path, which reads the newest persisted run and
                // names it.
                let checker = ConsistencyChecker()
                let consistencyResult = checkersToRun.isEmpty
                    ? try await checker.check(configuration: configuration)
                    : try await checker.audit(results: allResults, configuration: configuration)
                // Reconciled like every result the runner returns: this stage is the one
                // other place a result enters the run, so it is the one other place the
                // status is made to agree with the diagnostics.
                allResults.append(overrideProcessor.apply(to: consistencyResult).reconciled())
            } catch {
                // Loud, never silent: a corpus that cannot be read is a fact about the run.
                Self.logger.error("Consistency audit failed: \(error.localizedDescription, privacy: .public)")
                // `.skipped`, not `.passed`: an audit that threw compared nothing.
                allResults.append(CheckResult(
                    checkerId: ConsistencyChecker().id,
                    status: .skipped,
                    diagnostics: [Diagnostic(
                        severity: .note,
                        message: "Not checked: the consistency audit could not run: \(error.localizedDescription)",
                        ruleId: "consistency-unavailable"
                    )],
                    duration: .zero
                ).reconciled())
            }
        }
        // Every checker is done with the index. Release the shared sessions so each
        // IndexStoreDB closes cleanly — its database is renamed back to `v13/saved` only
        // in its destructor, and a process that exits holding a session strands the
        // database under a pid-unique name the next run discards and re-ingests.
        await SharedIndexStore.drain()

        // Decaying baseline (Phase 4c §3): recorded debts become notes with
        // their expiry visible; expired debts return as re-verify warnings;
        // new findings gate. Applied before trial mode so both transforms
        // see honest inputs. A ledger read failure is loud, never silent.
        // The ledger was already applied, per result, inside the run — see the `transform`
        // above. What is left here is only reading the counts back off the transformed
        // results. Derived rather than accumulated: the transform runs in a `@Sendable`
        // closure, and counting across results there would need a lock around numbers that
        // are recoverable from the output.
        var baselineSnapshot: BaselineSnapshot?
        if baselineLedger != nil {
            let summary = BaselineLedger.summarise(allResults)
            baselineSnapshot = BaselineSnapshot(
                baselined: summary.baselined,
                expired: summary.expired,
                newFindings: summary.newFindings)
            print("ℹ️  Baseline: \(summary.baselined) debt(s) covered, \(summary.expired) EXPIRED (re-verify), \(summary.newFindings) new finding(s) gating.")
        }

        // Trial mode (Phase 4 §3): the survey transform — findings visible,
        // nothing gates. Applied before reporting so terminal/SARIF/telemetry
        // all see the same downgraded truth.
        if advisoryAll {
            allResults = AdvisoryDowngrade.apply(to: allResults)
            print("ℹ️  Trial mode (--advisory-all): findings reported as notes; nothing gates this run.")
        }
        // A truncated run cannot exit 0. `allResults` is post-baseline, so a repository
        // with a ledger can present every executed checker as green while the runner
        // stopped early and never reached the rest — see TerminalReporter's INCOMPLETE
        // branch. Exiting 0 there would tell a CI job that a run which examined half the
        // roster had passed, which is the one answer this tool must never give.
        //
        // The verdict comes off the same `RunTally` the reporters print from. Under
        // `--strict` it reads the warning *count* — the number on the summary line — so a
        // run that prints `N warning(s)` with N > 0 cannot exit 0, whichever checker
        // emitted them and whatever status it chose for itself.
        let verdict = RunTally(allResults).verdict(
            strict: strict, truncated: runOutcome.truncation != nil)
        let hasFailure = verdict != .passed

        // Handle --bootstrap: generate initial status documents
        if bootstrap {
            let currentDir = configuration.resolvedProjectRoot.path
            let guidelinesDir = (currentDir as NSString).appendingPathComponent(
                configuration.status.guidelinesPath
            )
            // Honour the configured location rather than rebuilding the v1 path:
            // masterPlanPath is relative to guidelinesPath, exactly as StatusAuditor
            // resolves it. This project sets `guidelinesPath: "."` with a plan path that
            // leaves the tree entirely — the plan lives in a private companion repository
            // cloned as a sibling, so the relative path walks up out of the checkout.
            let masterPlanPath = (guidelinesDir as NSString).appendingPathComponent(
                configuration.status.masterPlanPath
            )
            let masterPlanDir = (masterPlanPath as NSString).deletingLastPathComponent

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
        let requestedIDs = CheckerSelection.normalise(check)
        let runScope: RunScope = (requestedIDs.isEmpty || requestedIDs.contains("all"))
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
                truncation: runOutcome.truncation,
                cache: noCache ? nil : resultCache,
                gateHash: gateHash,
                digests: digestCache,
                verbose: verbose
            )
        } else if verbose {
            print("\n[ijs] Foreign mode: telemetry silent (corpus not configured by the overlay)")
        }

        // Corpus participation advisory. Deliberately after emission, so a run that just
        // wrote its first telemetry reads as registered rather than being told to onboard
        // seconds after doing so.
        //
        // Printed here rather than inside a Reporter because it is not a result: JSON and
        // SARIF consumers have no use for it, and it must stay out of the diagnostic list
        // so it cannot affect error or warning counts under --strict.
        if outputFormat == .terminal, !runEnvironment.isForeign {
            let presence = corpusLocation.usablePath.map { path in
                CorpusPresenceProbe.probe(
                    corpusPath: path,
                    projectID: EffectiveProjectID.resolve(consistency: configuration.consistency)
                )
            }
            let advisory = CorpusRegistrationAdvisor.advise(
                config: configuration.consistency,
                presence: presence,
                gatePassed: !hasFailure
            )
            if let text = advisory.rendered() {
                print(text)
            }

            // Pulse freshness is a separate question about the same corpus, so it shares
            // the block but not the verdict: a registered project can be looking at a
            // corpus nobody has generated a pulse for in a week, and that is worth saying
            // even though its own registration is fine.
            if let path = corpusLocation.usablePath, !hasFailure {
                let freshness = PulseFreshnessProbe.probe(
                    corpusPath: path,
                    now: Date(),
                    staleAfterHours: configuration.consistency.pulseStaleAfterHours
                )
                if let text = freshness.rendered() {
                    // Only open a block if registration did not already open one.
                    if advisory.rendered() == nil {
                        print("\n── Corpus " + String(repeating: "─", count: 32))
                    }
                    print(text + "\n")
                }
            }
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
            try ReporterFactory.create(for: format, strict: strict).report(results, to: &rendered)
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

        guard let corpusPath = try ConfiguredCorpus.path(
            flag: nil, configuration: configuration, tag: "ijs") else {
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
