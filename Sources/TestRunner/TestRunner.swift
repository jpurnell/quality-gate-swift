import Foundation
#if canImport(os)
import os
#endif
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
/// import QualityGateCore
///
/// let config = Configuration()
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

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "`swift test` wrapper — parses Swift Testing and XCTest results; flip detector flags scheduler-dependent pass↔fail outcome changes on an unchanged package; optional stress mode re-runs `// TIMING:`-tagged tests to provoke races"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.projectHealth

    /// Spawns `swift test`, which locks the SwiftPM `.build` directory — must run
    /// sequentially, outside the concurrent task group.
    public var isParallelSafe: Bool { false }

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

        var result = Self.createResult(output: output, exitCode: exitCode, duration: ContinuousClock.now - startTime)

        // Test-outcome flip detection (scheduler-dependent behavior across runs).
        if configuration.flipDetector.enabled {
            result = runFlipDetection(
                on: result,
                output: output,
                projectRoot: projectRoot,
                configuration: configuration,
                startTime: startTime
            )
        }

        // Deliberate stress runs of timing-tagged tests (per-release / nightly).
        if configuration.stress.runs > 1 {
            result = await runStress(
                on: result,
                projectRoot: projectRoot,
                configuration: configuration,
                startTime: startTime
            )
        }

        return result
    }

    /// Re-runs the `// TIMING:`-tagged tests `stress.runs` times (optionally under CPU
    /// contention) and folds any intra-batch flip into `result`. A test that is not
    /// unanimous across the identical runs is a definitive race. No tagged tests → a
    /// `.note`, no runs. Best-effort: a failed stress invocation never crashes the gate.
    private func runStress(
        on result: CheckResult,
        projectRoot: String,
        configuration: Configuration,
        startTime: ContinuousClock.Instant
    ) async -> CheckResult {
        let stress = configuration.stress
        let tagged = Self.timingTests(projectRoot: projectRoot, marker: stress.marker)
        guard !tagged.isEmpty else {
            let note = Diagnostic(
                severity: .note,
                message: "stress mode: no '\(stress.marker)' tagged tests found — nothing to stress",
                ruleId: "test.stress-empty"
            )
            return withAppended([note], to: result, startTime: startTime)
        }

        // One `--filter <name>` per tagged test (swift test ORs multiple filters).
        var filterArgs: [String] = []
        for name in tagged { filterArgs.append(contentsOf: ["--filter", name]) }

        var rosters: [[TestOutcome]] = []
        await Self.withCPUContention(enabled: stress.contention) {
            for _ in 0..<stress.runs {
                // silent: a failed stress invocation is best-effort; skip that run's roster
                guard let (output, _) = try? await self.runSwiftTest(arguments: ["--parallel"] + filterArgs) else { continue }
                rosters.append(TestRosterParser.parse(output))
            }
        }

        let flips = StressAnalysis.flips(rosters: rosters)
        let diagnostics = StressAnalysis.diagnostics(for: flips, runs: stress.runs, strict: stress.strict)
        guard !diagnostics.isEmpty else { return result }
        return withAppended(diagnostics, to: result, startTime: startTime)
    }

    /// Appends `extra` to `result`, recomputing status to `.failed` if any error was added.
    private func withAppended(_ extra: [Diagnostic], to result: CheckResult, startTime: ContinuousClock.Instant) -> CheckResult {
        let merged = result.diagnostics + extra
        let status: CheckResult.Status = merged.contains { $0.severity == .error } ? .failed : result.status
        return CheckResult(
            checkerId: result.checkerId,
            status: status,
            diagnostics: merged,
            duration: ContinuousClock.now - startTime
        )
    }

    /// Unions the `// TIMING:`-tagged test names across every `.swift` file under `Tests/`.
    static func timingTests(projectRoot: String, marker: String) -> [String] {
        let testsDir = (projectRoot as NSString).appendingPathComponent("Tests")
        guard let enumerator = FileManager.default.enumerator(atPath: testsDir) else { return [] }
        var names: [String] = []
        var seen: Set<String> = []
        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            let path = (testsDir as NSString).appendingPathComponent(rel)
            // silent: an unreadable test file is skipped; stress scan is best-effort
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for name in TimingTestScanner.timingTests(in: source, marker: marker) where !seen.contains(name) {
                seen.insert(name)
                names.append(name)
            }
        }
        return names
    }

    /// Runs `body` under best-effort background CPU load sized to `cores − 1`, torn down
    /// on exit. A no-op when `enabled` is false.
    static func withCPUContention(enabled: Bool, _ body: () async -> Void) async {
        guard enabled else { await body(); return }
        let flag = ContentionFlag()
        let count = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        for _ in 0..<count {
            let thread = Thread {
                while !flag.isStopped { _ = (0..<10_000).reduce(0, +) }
            }
            thread.stackSize = 64 * 1024
            thread.start()
        }
        defer { flag.stop() }
        await body()
    }

    /// Persists this run's roster and folds any scheduler-dependent flips into `result`.
    ///
    /// A flip = a test whose pass/fail outcome changed while the package fingerprint did
    /// not, since the last run. Diagnostics are appended and (in strict mode) the status
    /// is recomputed. An empty roster (e.g. a build failure) never overwrites the stored
    /// history. All state IO is best-effort — the flip detector must never fail the gate.
    private func runFlipDetection(
        on result: CheckResult,
        output: String,
        projectRoot: String,
        configuration: Configuration,
        startTime: ContinuousClock.Instant
    ) -> CheckResult {
        let roster = TestRosterParser.parse(output)
        let rootURL = URL(fileURLWithPath: projectRoot)
        let key = rootURL.lastPathComponent.isEmpty ? "package" : rootURL.lastPathComponent
        let store = TestOutcomeStore.standard(projectRoot: rootURL)
        let previous = store.loadLatest(key: key)

        let (flipDiagnostics, newRecord) = Self.flipDetection(
            roster: roster,
            previous: previous,
            packageFingerprint: Self.packageFingerprint(projectRoot: projectRoot),
            commit: Self.currentCommit(projectRoot: projectRoot),
            loadProxy: configuration.parallelWorkers ?? ProcessInfo.processInfo.activeProcessorCount,
            strict: configuration.flipDetector.strict
        )

        if let newRecord {
            store.storeLatest(newRecord, key: key)
        }
        guard !flipDiagnostics.isEmpty else { return result }

        let merged = result.diagnostics + flipDiagnostics
        // A strict flip is an error → the gate must fail even if the suite itself passed.
        let status: CheckResult.Status = merged.contains { $0.severity == .error } ? .failed : result.status
        return CheckResult(
            checkerId: result.checkerId,
            status: status,
            diagnostics: merged,
            duration: ContinuousClock.now - startTime
        )
    }

    /// Digest of the package's `Sources`/`Tests` `.swift` files plus `Package.swift`.
    /// Two runs with an identical fingerprint are running byte-identical code under test.
    private static func packageFingerprint(projectRoot: String) -> String {
        let root = projectRoot as NSString
        var files: [String] = [root.appendingPathComponent("Package.swift")]
        for subdir in ["Sources", "Tests"] {
            let dir = root.appendingPathComponent(subdir)
            guard let enumerator = FileManager.default.enumerator(atPath: dir) else { continue }
            while let rel = enumerator.nextObject() as? String {
                guard rel.hasSuffix(".swift") else { continue }
                files.append((dir as NSString).appendingPathComponent(rel))
            }
        }
        return CheckerFingerprint.compute(
            checkerId: "test-roster",
            inputs: CacheInputs(files: files),
            gateHash: ""
        )
    }

    /// Short HEAD commit hash, or empty when git is unavailable. Best-effort.
    private static func currentCommit(projectRoot: String) -> String {
        // silent: commit hash is best-effort metadata; git absence must not fail the gate
        guard let output = try? ProcessRunner.run(
            "/usr/bin/git",
            arguments: ["rev-parse", "--short", "HEAD"],
            currentDirectory: projectRoot
        ), output.exitCode == 0 else { return "" }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // Roster parsing moved to VigilKit.TestRosterParser (Phase 4 extraction) —
    // the flip detector and stress analysis fingerprint what it produces.

    /// Builds diagnostics for scheduler-dependent outcome flips.
    ///
    /// Each flip is framed as "scheduler-dependent behavior detected — find the window"
    /// rather than "flaky test", and surfaces both commits so the regression window is
    /// bounded. Severity is `.warning` by default, `.error` under `strict`.
    ///
    /// - Parameters:
    ///   - flips: The flips detected by `FlipDetector`.
    ///   - strict: When true, emit `.error` instead of `.warning`.
    /// - Returns: One diagnostic per flip.
    public static func flipDiagnostics(for flips: [TestOutcomeFlip], strict: Bool) -> [Diagnostic] {
        flips.map { flip in
            let direction = "\(flip.previouslyPassed ? "pass" : "fail")→\(flip.nowPassed ? "pass" : "fail")"
            let scope = flip.suite.isEmpty ? flip.test : "\(flip.suite).\(flip.test)"
            return Diagnostic(
                severity: strict ? .error : .warning,
                message: "scheduler-dependent behavior detected: '\(scope)' flipped \(direction) with no change to its package (previous \(flip.previousCommit), current \(flip.currentCommit)) — find the window",
                ruleId: "test.outcome-flip",
                suggestedFix: "The test's package is byte-identical across these two runs, so the flip is a race, not a code change. Reproduce under load and fix the timing window."
            )
        }
    }

    /// Composes roster parsing, flip detection, and diagnostic mapping for one run.
    ///
    /// Returns the flip diagnostics plus the record to persist. When the roster is empty
    /// — e.g. a build failure meant no tests ran — this returns **no** record so the caller
    /// does not overwrite (and lose) the last good roster, and emits no flip diagnostics.
    ///
    /// - Parameters:
    ///   - roster: The parsed per-test outcomes for this run.
    ///   - previous: The last persisted record for this package (nil on first run).
    ///   - packageFingerprint: Digest of the package sources + manifest at run time.
    ///   - commit: Short commit hash at run time.
    ///   - loadProxy: Concurrent worker/gate count at run time.
    ///   - strict: When true, flip diagnostics are `.error` instead of `.warning`.
    /// - Returns: The flip diagnostics and the record to persist (nil to skip persistence).
    public static func flipDetection(
        roster: [TestOutcome],
        previous: TestRunRecord?,
        packageFingerprint: String,
        commit: String,
        loadProxy: Int,
        strict: Bool
    ) -> (diagnostics: [Diagnostic], newRecord: TestRunRecord?) {
        // No tests ran (e.g. compile failure) — do not disturb the stored history.
        guard !roster.isEmpty else { return ([], nil) }

        let current = TestRunRecord(
            packageFingerprint: packageFingerprint,
            commit: commit,
            loadProxy: loadProxy,
            outcomes: roster
        )
        let flips = FlipDetector.flips(previous: previous, current: current)
        return (flipDiagnostics(for: flips, strict: strict), current)
    }

    // StressFlip / stress-flip analysis moved to VigilKit.StressAnalysis
    // (Phase 4 extraction) — orchestration (spawning, contention) stays here.

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

/// Thread-safe stop flag for the best-effort CPU-contention harness.
// Justification: a single Bool guarded by NSLock for cross-thread stop signaling; no data race is possible.
private final class ContentionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    /// Whether the harness has been asked to stop.
    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Signals every contention thread to exit.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
