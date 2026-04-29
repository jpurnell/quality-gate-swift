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
        version: "1.0.0"
    )

    @Option(name: .shortAndLong, help: "Output format (terminal, json, sarif)")
    var format: String = "terminal"

    @Option(name: .shortAndLong, help: "Path to configuration file")
    var config: String = ".quality-gate.yml"

    @Option(name: .long, parsing: .upToNextOption, help: "Specific checkers to run (build, test, safety, doc-lint, doc-coverage, unreachable, recursion, concurrency, pointer-escape, accessibility, swift-version, test-quality, disk-clean)")
    var check: [String] = []

    @Flag(name: .long, help: "Continue running checks even if one fails")
    var continueOnFailure: Bool = false

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    @Flag(name: .long, help: "Drive `xcodebuild build` automatically when the unreachable checker can't find a fresh DerivedData index store for an Xcode project / workspace.")
    var autoBuildXcode: Bool = false

    @Flag(name: .long, help: "Apply auto-fixes for checkers that support FixableChecker protocol")
    var fix: Bool = false

    @Flag(name: .long, help: "Show what --fix would change without applying (requires --fix)")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Generate initial status documents from actual project state (use with --check status)")
    var bootstrap: Bool = false

    func run() async throws {
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
                logging: configuration.logging
            )
        }

        // Determine effective checkers based on --check flag or configuration
        let effectiveCheckers: [String]
        if !check.isEmpty {
            effectiveCheckers = check
        } else if !configuration.enabledCheckers.isEmpty {
            effectiveCheckers = configuration.enabledCheckers
        } else {
            effectiveCheckers = [
                "build", "test", "safety", "doc-lint", "doc-coverage",
                "unreachable", "recursion", "concurrency", "pointer-escape",
                "accessibility", "swift-version", "logging", "test-quality"
            ]
        }

        // Build the list of checkers to run
        // Note: DiskCleaner is not included in defaults as it's destructive
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
            DiskCleaner()
        ]

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
                let result = try await checker.check(configuration: configuration)
                allResults.append(result)

                if result.status == .failed {
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
}
