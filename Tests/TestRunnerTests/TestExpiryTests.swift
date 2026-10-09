import Foundation
import Testing
@testable import TestRunner
@testable import QualityGateCore

// `swift test` stopped at its budget must say exactly that — which checker, what the budget
// was and why, how long it ran, how loaded the machine was, what it had printed, and what to
// do next. And a run that fails without a single test failure to show must say that too:
// `✗ [test] FAILED` over nothing is the same silence with a different exit code.

/// A package directory holding only a manifest, which is all `check` asks for before it
/// launches the tool.
private func scratchPackage() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("qg-test-expiry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\n".write(
        to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    return root
}

/// Records what the launcher was asked to run.
// Justification: both arrays are only touched under `lock`; the class holds no other state.
private final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTimeouts: [TimeInterval] = []
    private var recordedCommands: [[String]] = []

    func record(_ invocation: ToolLauncher.Invocation) {
        lock.lock(); defer { lock.unlock() }
        recordedTimeouts.append(invocation.timeout)
        recordedCommands.append(invocation.arguments)
    }

    var timeouts: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return recordedTimeouts
    }

    var commands: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recordedCommands
    }
}

/// A launcher answering every invocation with `output`, on a clock that moves `elapsed`
/// seconds per run, under `load`.
private func launcher(
    answering output: ToolLauncher.Output,
    elapsed: TimeInterval,
    load: MachineLoad?,
    seen: Launches
) -> ToolLauncher {
    let clock = TickingClock(step: elapsed)
    return ToolLauncher(
        launch: { invocation in
            seen.record(invocation)
            return output
        },
        monotonicSeconds: { clock.next() },
        load: { load })
}

// Justification: `reading` is only touched under `lock`; the class holds no other state.
private final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var reading: TimeInterval = 0
    private let step: TimeInterval
    init(step: TimeInterval) { self.step = step }
    func next() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let value = reading
        reading += step
        return value
    }
}

private let kernelNote = "\nprocess-kernel: `/usr/bin/swift` timed out after 900s and was terminated."

@Suite("test: stopped at the budget, or failed without a test failure")
struct TestExpiryTests {

    private func run(
        exitCode: Int32, stdout: String, stderr: String = "", elapsed: TimeInterval = 905
    ) -> ToolRun {
        ToolRun(
            checkerId: "test", command: "swift test --parallel", directory: "/work/pkg",
            stdout: stdout, stderr: stderr, exitCode: exitCode,
            budget: CheckerBudget.Allowance(checkerId: "test", seconds: 900, source: .lastSuccess(212)),
            elapsed: elapsed, load: MachineLoad(oneMinute: 187.4, activeProcessors: 10))
    }

    @Test("A cut-off run is one error that states the budget, the elapsed time and the load")
    func expiryIsReportedInFull() throws {
        let cutOff = run(
            exitCode: 124,
            stdout: "􁁛  Test run with 94 tests in 7 suites passed after 144.502 seconds.\n􀟈  Test \"A slow one\" started.\n",
            stderr: kernelNote)

        let result = TestRunner.createResult(run: cutOff, duration: .seconds(905))

        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["test-timeout"])
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message == """
            `swift test --parallel` was stopped at its time budget and did not finish. This run \
            is incomplete: it is not a pass, and it is not a finding about the code.
              checker: test
              budget:  900s — three times the last successful run (212s), and never less than 900s
              elapsed: 905s
              load:    1-minute load average 187.4 on 10 cores (18.7 per core)
              last 2 lines of output:
                | 􁁛  Test run with 94 tests in 7 suites passed after 144.502 seconds.
                | 􀟈  Test "A slow one" started.
            """)
        #expect(diagnostic.suggestedFix == """
            Rerun this checker alone, when the load is lower: `quality-gate --check test`. If it \
            needs longer than 900s on a quiet machine, raise its budget in .quality-gate.yml — \
            `budgets:` then `test: 1800` (seconds).
            """)
    }

    @Test("A cut-off run keeps the test failures it had already recorded, beside the expiry")
    func expiryKeepsRecordedFailures() {
        let cutOff = run(
            exitCode: 124,
            stdout: "􀢄  Test \"adds\" recorded an issue at MathTests.swift:12:5: Expectation failed: 1 + 1 == 3\n",
            stderr: kernelNote)
        let result = TestRunner.createResult(run: cutOff, duration: .seconds(905))
        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["test-failure", "test-timeout"])
    }

    @Test("A failed run with no test failure to show says what the tool printed")
    func unparsedFailureIsReported() throws {
        let broken = run(
            exitCode: 1,
            stdout: "Building for debugging...\nerror: no such module 'Vapor'\nerror: fatalError\n",
            elapsed: 15)

        let result = TestRunner.createResult(run: broken, duration: .seconds(15))

        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["test-unparsed-failure"])
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message == """
            `swift test --parallel` exited 1 and nothing it printed is a diagnostic this checker \
            can parse. It was not stopped by its time budget.
              checker: test
              budget:  900s — three times the last successful run (212s), and never less than 900s
              elapsed: 15s
              load:    1-minute load average 187.4 on 10 cores (18.7 per core)
              last 3 lines of output:
                | Building for debugging...
                | error: no such module 'Vapor'
                | error: fatalError
            """)
        #expect(diagnostic.suggestedFix == """
            Rerun this checker alone: `quality-gate --check test`. For the whole transcript, run \
            `swift test --parallel` in /work/pkg.
            """)
    }

    @Test("A run that failed because a test failed reports the test, and nothing about parsing")
    func parsedFailureNeedsNoExplanation() {
        let failed = run(
            exitCode: 1,
            stdout: "􀢄  Test \"adds\" recorded an issue at MathTests.swift:12:5: Expectation failed: 1 + 1 == 3\n",
            elapsed: 15)
        let result = TestRunner.createResult(run: failed, duration: .seconds(15))
        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["test-failure"])
    }

    @Test("A transcript without its run still reports the expiry, with the budget the kernel named")
    func transcriptAloneStillNamesTheBudget() throws {
        let result = TestRunner.createResult(
            output: "\nprocess-kernel: `/usr/bin/swift` timed out after 600s and was terminated.",
            exitCode: 124, duration: .seconds(600))
        let diagnostic = try #require(result.diagnostics.first)
        #expect(result.diagnostics.count == 1)
        #expect(diagnostic.ruleId == "test-timeout")
        #expect(diagnostic.message.contains("\n  budget:  600s — as the process runner reported it\n"))
        #expect(diagnostic.message.hasSuffix("\n  the tool had printed nothing when it was stopped"))
    }

    // MARK: - The checker, end to end, with nothing launched

    @Test("The checker runs swift test under the configured budget, and an expiry records no duration")
    func configuredBudgetReachesTheToolAndExpiryIsNotRecorded() async throws {
        let root = try scratchPackage()
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort cleanup of a temporary fixture
        let seen = Launches()
        let runner = TestRunner(launcher: launcher(
            answering: .init(stdout: "", stderr: kernelNote, exitCode: 124),
            elapsed: 42, load: MachineLoad(oneMinute: 96, activeProcessors: 12), seen: seen))
        var configuration = Configuration(budgets: try CheckerBudgetsConfig(["test": 42]))
        configuration.projectRoot = root

        let result = try await runner.check(configuration: configuration)

        #expect(seen.timeouts == [42])
        #expect(seen.commands == [["test", "--parallel"]])
        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["test-timeout"])
        let message = try #require(result.diagnostics.first?.message)
        #expect(message.contains("\n  budget:  42s — set by `budgets.test` in .quality-gate.yml\n"))
        #expect(message.contains("\n  elapsed: 42s\n"))
        #expect(message.contains("\n  load:    1-minute load average 96.0 on 12 cores (8.0 per core)\n"))
        #expect(CheckerBudget.lastSuccess(named: "test", root: root.path) == nil)
    }

    @Test("With nothing configured or recorded the first-run budget applies, and a success is recorded")
    func firstRunBudgetAndSuccessIsRecorded() async throws {
        let root = try scratchPackage()
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort cleanup of a temporary fixture
        let seen = Launches()
        let runner = TestRunner(launcher: launcher(
            answering: .init(
                stdout: "􁁛  Test run with 3 tests in 1 suite passed after 0.2 seconds.\n",
                stderr: "", exitCode: 0),
            elapsed: 37, load: nil, seen: seen))
        var configuration = Configuration()
        configuration.projectRoot = root

        let result = try await runner.check(configuration: configuration)

        #expect(seen.timeouts == [3_600])
        #expect(result.status == .passed)
        #expect(CheckerBudget.lastSuccess(named: "test", root: root.path) == 37)
    }
}
