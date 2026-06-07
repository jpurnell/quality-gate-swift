
import ArgumentParser
import Foundation
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
import ReleaseReadinessAuditor
import FloatingPointSafetyAuditor
import StochasticDeterminismAuditor
import MCPReadinessAuditor
import ProcessSafetyAuditor
import MemoryLifecycleGuard
import ComplexityAnalyzer
import HIGAuditor
import AppIntentsAuditor
import XcodeBuildChecker
import ConsistencyChecker
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
    static let configuration = CommandConfiguration(
        commandName: "quality-gate",
        abstract: "Run automated quality checks on a Swift project.",
        version: "2.0.0",
        subcommands: [Calibrate.self, TelemetryPush.self, GeneratePulse.self, GenerateNarrative.self, Dashboard.self, GenerateManifest.self, BuildInfo.self]
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

    @Option(name: .long, help: "Override cognitive complexity threshold (used with --check complexity)")
    var threshold: Int?

    @Option(name: .long, help: "Override corpus path for telemetry (useful for CI)")
    var corpusPath: String?

    func run() async throws {
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

        // Load configuration
        var configuration: Configuration
        do {
            configuration = try Configuration.load(from: config)
        } catch {
            configuration = Configuration()
            if verbose {
                print("Warning: failed to load \(config): \(error). Using defaults.")
            }
        }
        // CLI flag overrides config (v5).
        if autoBuildXcode && !configuration.unreachableAutoBuildXcode {
            configuration = Configuration(
                parallelWorkers: configuration.parallelWorkers,
                excludePatterns: configuration.excludePatterns,
                safetyExemptions: configuration.safetyExemptions,
                enabledCheckers: configuration.enabledCheckers,
                buildConfiguration: configuration.buildConfiguration,
                testFilter: configuration.testFilter,
                docTarget: configuration.docTarget,
                docCoverageThreshold: configuration.docCoverageThreshold,
                unreachableAutoBuildXcode: true,
                xcodeScheme: configuration.xcodeScheme,
                xcodeDestination: configuration.xcodeDestination,
                concurrency: configuration.concurrency,
                pointerEscape: configuration.pointerEscape,
                security: configuration.security,
                status: configuration.status,
                swiftVersion: configuration.swiftVersion,
                memoryBuilder: configuration.memoryBuilder,
                logging: configuration.logging,
                dependencyAudit: configuration.dependencyAudit,
                releaseReadiness: configuration.releaseReadiness,
                fpSafety: configuration.fpSafety,
                stochasticDeterminism: configuration.stochasticDeterminism,
                memoryLifecycle: configuration.memoryLifecycle,
                mcpReadiness: configuration.mcpReadiness,
                build: configuration.build,
                xcodeBuild: configuration.xcodeBuild,
                consistency: configuration.consistency,
                overrides: configuration.overrides
            )
        }

        if let thresholdOverride = threshold {
            configuration.complexity = ComplexityAnalyzerConfig(
                cognitiveThreshold: thresholdOverride,
                reportTopN: configuration.complexity.reportTopN,
                moduleThresholds: configuration.complexity.moduleThresholds,
                emitToCorpus: configuration.complexity.emitToCorpus,
                callGraphEnabled: configuration.complexity.callGraphEnabled,
                callGraphMaxDepth: configuration.complexity.callGraphMaxDepth,
                knownCosts: configuration.complexity.knownCosts
            )
        }

        if let corpusPathOverride = corpusPath {
            let c = configuration.consistency
            configuration = Configuration(
                parallelWorkers: configuration.parallelWorkers,
                excludePatterns: configuration.excludePatterns,
                safetyExemptions: configuration.safetyExemptions,
                enabledCheckers: configuration.enabledCheckers,
                buildConfiguration: configuration.buildConfiguration,
                testFilter: configuration.testFilter,
                docTarget: configuration.docTarget,
                docCoverageThreshold: configuration.docCoverageThreshold,
                unreachableAutoBuildXcode: configuration.unreachableAutoBuildXcode,
                xcodeScheme: configuration.xcodeScheme,
                xcodeDestination: configuration.xcodeDestination,
                concurrency: configuration.concurrency,
                pointerEscape: configuration.pointerEscape,
                security: configuration.security,
                status: configuration.status,
                swiftVersion: configuration.swiftVersion,
                memoryBuilder: configuration.memoryBuilder,
                logging: configuration.logging,
                dependencyAudit: configuration.dependencyAudit,
                releaseReadiness: configuration.releaseReadiness,
                fpSafety: configuration.fpSafety,
                stochasticDeterminism: configuration.stochasticDeterminism,
                memoryLifecycle: configuration.memoryLifecycle,
                mcpReadiness: configuration.mcpReadiness,
                build: configuration.build,
                xcodeBuild: configuration.xcodeBuild,
                consistency: ConsistencyCheckerConfig(
                    corpusPath: corpusPathOverride,
                    projectID: c.projectID,
                    consistencyThreshold: c.consistencyThreshold,
                    defaultRiskTier: c.defaultRiskTier,
                    scorerWeights: c.scorerWeights,
                    exemptions: c.exemptions
                ),
                overrides: configuration.overrides
            )
        }

        // Create override processor from configuration.
        let overrideProcessor = OverrideProcessor(overrides: configuration.overrides)

        // Build the full checker registry (order matters for output)
        let allCheckers: [any QualityChecker] = [
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
                justificationKeyword: configuration.concurrency.justificationKeyword
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
            ReleaseReadinessAuditor(),
            FloatingPointSafetyAuditor(),
            StochasticDeterminismAuditor(),
            MemoryLifecycleGuard(),
            MCPReadinessAuditor(),
            ProcessSafetyAuditor(),
            ComplexityAnalyzer(),
            HIGAuditor(),
            AppIntentsAuditor(),
            ConsistencyChecker(),
            XcodeBuildChecker(),
            DiskCleaner()
        ]

        // Determine effective checkers: --check all | --check X Y | config | defaults
        let effectiveCheckers: [String]
        if check.contains("all") {
            let allIDs = allCheckers.map(\.id)
            let excludeSet = Set(exclude)
            effectiveCheckers = allIDs.filter { !excludeSet.contains($0) }
        } else if !check.isEmpty {
            effectiveCheckers = check
        } else if !configuration.enabledCheckers.isEmpty {
            effectiveCheckers = configuration.enabledCheckers
        } else {
            var optOutCheckers: Set<String> = ["disk-clean", "xcode-build"]
            if full {
                optOutCheckers.remove("xcode-build")
            }
            effectiveCheckers = allCheckers.map(\.id).filter { !optOutCheckers.contains($0) }
        }

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

        var allResults: [CheckResult] = []
        var hasFailure = false

        // Run each checker
        for checker in checkersToRun {
            if verbose {
                print("Running \(checker.name)...")
            }

            do {
                let rawResult = try await checker.check(configuration: configuration)
                let result = overrideProcessor.apply(to: rawResult)
                allResults.append(result)

                let isFailing = result.status == .failed
                    || (strict && result.status == .warning)
                if isFailing {
                    hasFailure = true
                    if !continueOnFailure {
                        break
                    }
                }
            } catch {
                let errorResult = CheckResult(
                    checkerId: checker.id,
                    status: .failed,
                    diagnostics: [
                        Diagnostic(
                            severity: .error,
                            message: "Checker failed: \(error.localizedDescription)",
                            ruleId: "checker-error"
                        )
                    ],
                    duration: .zero
                )
                allResults.append(errorResult)
                hasFailure = true

                if !continueOnFailure {
                    break
                }
            }
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

        // Emit telemetry to IJS corpus if configured
        if let corpusPath = configuration.consistency.corpusPath {
            let ijsConfig = configuration.consistency
            let projectID = ijsConfig.projectID
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent
            let riskTier = RiskTier(rawValue: ijsConfig.defaultRiskTier) ?? .operational
            let consistencyResult = allResults.first { $0.checkerId == "consistency" }
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
            let allOverrides = allResults.flatMap(\.overrides)
            let overrideRecords = allOverrides.map { override in
                OverrideRecord(
                    diagnosticOverride: override,
                    author: author,
                    riskTier: riskTier,
                    authorityLevel: riskTier.requiredAuthority
                )
            }

            let runTimestamp = Date()
            let metadata = CheckResultMetadata(
                projectID: projectID,
                timestamp: runTimestamp,
                environment: isCI ? .ci : .local,
                decisionOwner: author,
                results: allResults,
                overrides: overrideRecords,
                riskTier: riskTier,
                ethicalFlags: [],
                consistencyScore: consistencyScore
            )

            let calibrations = CalibrationClassifier.classify(
                overrides: allOverrides,
                decisionOwner: author,
                practitioner: author,
                riskTier: riskTier,
                timestamp: runTimestamp
            )

            do {
                let corpus = CorpusPath(basePath: corpusPath, projectID: projectID)
                let writer = TelemetryWriter()
                try await writer.write(metadata: metadata, calibrations: calibrations, to: corpus)

                if configuration.complexity.emitToCorpus {
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

                if verbose {
                    print("\n[ijs] Telemetry written to \(corpus.projectDirectory)")
                    if !calibrations.isEmpty {
                        print("[ijs] \(calibrations.count) calibration(s) auto-generated")
                    }
                }
            } catch {
                if verbose {
                    print("\n[ijs] Telemetry write failed: \(error.localizedDescription)")
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

    private func recordSkip(issueReference: String) async throws {
        var configuration: Configuration
        do {
            configuration = try Configuration.load(from: config)
        } catch {
            configuration = Configuration()
        }

        guard let corpusPath = configuration.consistency.corpusPath else {
            print("[ijs] No corpus configured — skip not recorded.")
            return
        }

        let projectID = configuration.consistency.projectID
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent
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
            let writer = TelemetryWriter()
            try await writer.writeSkip(record, to: corpus)
            print("[ijs] Skip recorded to corpus for \(projectID)")
        } catch {
            print("[ijs] Skip recording failed: \(error.localizedDescription)")
        }
    }
}
