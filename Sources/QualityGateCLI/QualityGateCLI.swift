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

    @Option(name: .long, parsing: .upToNextOption, help: "Specific checkers to run (build, test, safety, doc-lint, doc-coverage, unreachable, recursion, concurrency, pointer-escape, accessibility, disk-clean)")
    var check: [String] = []

    @Flag(name: .long, help: "Continue running checks even if one fails")
    var continueOnFailure: Bool = false

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    @Flag(name: .long, help: "Drive `xcodebuild build` automatically when the unreachable checker can't find a fresh DerivedData index store for an Xcode project / workspace.")
    var autoBuildXcode: Bool = false

    func run() async throws {
        // Load configuration
        var configuration: Configuration
        do {
            configuration = try Configuration.load(from: config)
        } catch {
            configuration = Configuration()
            if verbose {
                print("No configuration file found, using defaults")
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
                pointerEscape: configuration.pointerEscape
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
                "accessibility"
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

        // Output results
        var outputStream = StandardOutputStream()
        try reporter.report(allResults, to: &outputStream)

        // Exit with appropriate code
        if hasFailure {
            throw ExitCode(1)
        }
    }
}
