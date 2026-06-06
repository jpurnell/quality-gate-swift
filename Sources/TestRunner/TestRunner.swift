import Foundation
import os
import QualityGateCore

/// Executes `swift test` with parallel workers and reports results.
///
/// TestRunner runs the Swift test suite and parses the output to extract
/// test failures as structured diagnostics. It supports both Swift Testing
/// and XCTest output formats.
///
/// ## Usage
///
/// ```swift
/// let runner = TestRunner()
/// let result = try await runner.check(configuration: config)
/// ```
///
/// ## Configuration
///
/// Configure via `.quality-gate.yml`:
///
/// ```yaml
/// parallel_workers: 4    # Number of parallel test workers
/// test_filter: "MyTests" # Run only matching tests
/// ```
public struct TestRunner: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "TestRunner")

    /// Unique identifier for this checker.
    public let id = "test"

    /// Human-readable name for this checker.
    public let name = "Test Runner"

    /// Creates a new TestRunner instance.
    public init() {}

    /// Run the test suite.
    ///
    /// Executes `swift test` and parses any test failures.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let projectRoot = FileManager.default.currentDirectoryPath
        let packagePath = (projectRoot as NSString).appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: packagePath) else { // SAFETY: CLI reads Package.swift from cwd; no user-supplied path component
            let duration = ContinuousClock.now - startTime
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No Package.swift found; skipping test run.",
                        ruleId: "test-skip"
                    )
                ],
                duration: duration
            )
        }

        let args = testArguments(for: configuration)
        let (output, exitCode) = try await runSwiftTest(arguments: args)

        let duration = ContinuousClock.now - startTime
        return Self.createResult(output: output, exitCode: exitCode, duration: duration)
    }

    // MARK: - Public API for Testing

    /// Test summary information extracted from output.
    public struct TestSummary: Sendable {
        /// Total number of tests executed.
        public let totalTests: Int

        /// Number of tests that failed.
        public let failedTests: Int
    }

    /// Parse test output into diagnostics.
    ///
    /// Supports both Swift Testing and XCTest output formats.
    ///
    /// - Parameter output: The raw output from `swift test`
    /// - Returns: An array of diagnostics for any test failures
    public static func parseTestOutput(_ output: String) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        // Parse Swift Testing format:
        // Test "name" recorded an issue at File.swift:line:column: message
        let swiftTestingPattern = #"Test \"[^\"]+\" recorded an issue at ([^:]+):(\d+):(\d+): (.+)$"#

        do {
            let regex = try NSRegularExpression(pattern: swiftTestingPattern, options: .anchorsMatchLines)
            let range = NSRange(output.startIndex..., in: output)
            let matches = regex.matches(in: output, options: [], range: range)

            for match in matches {
                guard match.numberOfRanges == 5 else { continue }

                let fileRange = Range(match.range(at: 1), in: output)
                let lineRange = Range(match.range(at: 2), in: output)
                let columnRange = Range(match.range(at: 3), in: output)
                let messageRange = Range(match.range(at: 4), in: output)

                guard let fileRange, let lineRange, let columnRange, let messageRange else { continue }

                let file = String(output[fileRange])
                let line = Int(output[lineRange])
                let column = Int(output[columnRange])
                let message = String(output[messageRange])

                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: message,
                    filePath: file,
                    lineNumber: line,
                    columnNumber: column,
                    ruleId: "test-failure"
                ))
            }
        } catch {
            logger.warning("Failed to compile Swift Testing regex: \(error.localizedDescription, privacy: .public)")
        }

        // Parse XCTest format:
        // /path/to/File.swift:line: error: -[TestClass testMethod] : message
        let xcTestPattern = #"^(.+?):(\d+): error: -\[[^\]]+\] : (.+)$"#

        do {
            let regex = try NSRegularExpression(pattern: xcTestPattern, options: .anchorsMatchLines)
            let range = NSRange(output.startIndex..., in: output)
            let matches = regex.matches(in: output, options: [], range: range)

            for match in matches {
                guard match.numberOfRanges == 4 else { continue }

                let fileRange = Range(match.range(at: 1), in: output)
                let lineRange = Range(match.range(at: 2), in: output)
                let messageRange = Range(match.range(at: 3), in: output)

                guard let fileRange, let lineRange, let messageRange else { continue }

                let file = String(output[fileRange])
                let line = Int(output[lineRange])
                let message = String(output[messageRange])

                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: message,
                    filePath: file,
                    lineNumber: line,
                    ruleId: "test-failure"
                ))
            }
        } catch {
            logger.warning("Failed to compile XCTest regex: \(error.localizedDescription, privacy: .public)")
        }

        return diagnostics
    }

    /// Parse test summary from output.
    ///
    /// Extracts total test count and failure count from the test run summary line.
    ///
    /// - Parameter output: The raw test output
    /// - Returns: A TestSummary if found, nil otherwise
    public static func parseTestSummary(_ output: String) -> TestSummary? {
        // Swift Testing format: "Test run with X tests [in Y suites] passed/failed [after Z seconds] [with N issues]"
        let passedPattern = #"Test run with (\d+) tests.*passed"#
        let failedPattern = #"Test run with (\d+) tests.*failed.*with (\d+) issues"#
        let failedNoCountPattern = #"Test run with (\d+) tests.*failed"#

        // Try failed with issue count first
        do {
            let regex = try NSRegularExpression(pattern: failedPattern)
            if let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
                if let totalRange = Range(match.range(at: 1), in: output),
                   let failedRange = Range(match.range(at: 2), in: output),
                   let total = Int(output[totalRange]),
                   let failed = Int(output[failedRange]) {
                    return TestSummary(totalTests: total, failedTests: failed)
                }
            }
        } catch {
            logger.warning("Failed to compile test summary failed-pattern regex: \(error.localizedDescription, privacy: .public)")
        }

        // Try failed without issue count
        do {
            let regex = try NSRegularExpression(pattern: failedNoCountPattern)
            if let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
                if let totalRange = Range(match.range(at: 1), in: output),
                   let total = Int(output[totalRange]) {
                    return TestSummary(totalTests: total, failedTests: 1)
                }
            }
        } catch {
            logger.warning("Failed to compile test summary failed-no-count regex: \(error.localizedDescription, privacy: .public)")
        }

        // Try passed
        do {
            let regex = try NSRegularExpression(pattern: passedPattern)
            if let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
                if let totalRange = Range(match.range(at: 1), in: output),
                   let total = Int(output[totalRange]) {
                    return TestSummary(totalTests: total, failedTests: 0)
                }
            }
        } catch {
            logger.warning("Failed to compile test summary passed-pattern regex: \(error.localizedDescription, privacy: .public)")
        }

        return nil
    }

    /// Create a CheckResult from test output.
    ///
    /// - Parameters:
    ///   - output: The raw test output
    ///   - exitCode: The exit code from `swift test`
    ///   - duration: How long the tests took
    /// - Returns: A CheckResult summarizing the test run
    public static func createResult(
        output: String,
        exitCode: Int32,
        duration: Duration
    ) -> CheckResult {
        var diagnostics = parseTestOutput(output)

        let status: CheckResult.Status
        if exitCode == 0 {
            status = .passed
        } else {
            let hasTestFailures = !diagnostics.isEmpty
            let summary = parseTestSummary(output)
            let allTestsPassed = summary.map { $0.failedTests == 0 } ?? false

            if !hasTestFailures && allTestsPassed && isCodeSigningError(output) {
                status = .passed
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Ad-hoc code signing failed (tests passed)",
                    ruleId: "test-codesign"
                ))
            } else {
                status = .failed
            }
        }

        return CheckResult(
            checkerId: "test",
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    private static func isCodeSigningError(_ output: String) -> Bool {
        output.contains("Code Signing subsystem") || output.contains("codesign failed")
    }

    /// Generate test arguments based on configuration.
    ///
    /// - Parameter configuration: The project configuration
    /// - Returns: Arguments to pass to `swift test`
    public func testArguments(for configuration: Configuration) -> [String] {
        var args: [String] = []

        // Always use parallel testing
        args.append("--parallel")

        // Apply test filter if specified
        if let filter = configuration.testFilter {
            args.append("--filter")
            args.append(filter)
        }

        return args
    }

    // MARK: - Private Implementation

    private func runSwiftTest(arguments: [String]) async throws -> (output: String, exitCode: Int32) {
        // SAFETY: runs swift test to execute the project's test suite
        let result = try ProcessRunner.run(
            "/usr/bin/swift",
            arguments: ["test"] + arguments
        )

        // Combine stdout and stderr
        let combinedOutput = result.stdout + "\n" + result.stderr

        return (combinedOutput, result.exitCode)
    }
}
