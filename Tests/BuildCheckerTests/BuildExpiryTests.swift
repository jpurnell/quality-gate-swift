import Foundation
import Testing
@testable import BuildChecker
@testable import QualityGateCore

// `swift build` ran under the process runner's 600-second default — a figure chosen for
// `git rev-parse` — and a build stopped there was reported as `build-unparsed-failure`:
// "exit 124" and twenty lines of whatever the compiler had been doing. It did not say the
// build was stopped, what the budget was, or that the machine's load average was 200.

private func scratchPackage() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("qg-build-expiry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.0\n".write(
        to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    return root
}

// Justification: `recorded` is only touched under `lock`; the class holds no other state.
private final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    func record(_ invocation: ToolLauncher.Invocation) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(invocation.timeout)
    }

    var timeouts: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
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

private func launcher(
    answering output: ToolLauncher.Output, elapsed: TimeInterval, seen: Launches
) -> ToolLauncher {
    let clock = TickingClock(step: elapsed)
    return ToolLauncher(
        launch: { invocation in
            seen.record(invocation)
            return output
        },
        monotonicSeconds: { clock.next() },
        load: { MachineLoad(oneMinute: 212.5, activeProcessors: 10) })
}

private let kernelNote = "\nprocess-kernel: `/usr/bin/swift` timed out after 3600s and was terminated."

@Suite("build: stopped at the budget, or failed without a compiler diagnostic")
struct BuildExpiryTests {

    private func run(exitCode: Int32, stdout: String, stderr: String = "", elapsed: TimeInterval) -> ToolRun {
        ToolRun(
            checkerId: "build", command: "swift build --build-tests", directory: "/work/pkg",
            stdout: stdout, stderr: stderr, exitCode: exitCode,
            budget: CheckerBudget.Allowance(checkerId: "build", seconds: 3_600, source: .firstRun),
            elapsed: elapsed, load: MachineLoad(oneMinute: 212.5, activeProcessors: 10))
    }

    @Test("A cut-off build is a timeout, by name, and not an unparsed failure")
    func expiryIsNamed() throws {
        let cutOff = run(
            exitCode: 124,
            stdout: "Building for debugging...\n[412/975] Compiling SafetyAuditor SafetyVisitor.swift\n",
            stderr: kernelNote, elapsed: 3_605)

        let result = BuildChecker.createResult(run: cutOff, duration: .seconds(3_605))

        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["build-timeout"])
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message == """
            `swift build --build-tests` was stopped at its time budget and did not finish. This \
            run is incomplete: it is not a pass, and it is not a finding about the code.
              checker: build
              budget:  3600s — the first-run budget, because no successful run is recorded yet
              elapsed: 3605s
              load:    1-minute load average 212.5 on 10 cores (21.3 per core)
              last 2 lines of output:
                | Building for debugging...
                | [412/975] Compiling SafetyAuditor SafetyVisitor.swift
            """)
        #expect(diagnostic.suggestedFix == """
            Rerun this checker alone, when the load is lower: `quality-gate --check build`. If \
            it needs longer than 3600s on a quiet machine, raise its budget in .quality-gate.yml \
            — `budgets:` then `build: 7200` (seconds).
            """)
    }

    @Test("A cut-off build keeps the compiler errors it had printed, beside the expiry")
    func expiryKeepsCompilerErrors() {
        let cutOff = run(
            exitCode: 124,
            stdout: "/work/pkg/Sources/A/A.swift:3:5: error: cannot find 'x' in scope\n",
            stderr: kernelNote, elapsed: 3_605)
        let result = BuildChecker.createResult(run: cutOff, duration: .seconds(3_605), projectRoot: "/work/pkg")
        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["swift-compiler", "build-timeout"])
    }

    @Test("A package-resolution failure is shown as SwiftPM printed it, with the run's facts")
    func resolutionFailureShowsSwiftPMsOwnError() throws {
        // What a fresh linked worktree's first build printed inside a git hook, before the
        // hook's GIT_DIR was kept out of the build tools: fifteen seconds, exit 1, and not
        // one line shaped like a compiler diagnostic.
        let progress = (1...22).map { "Fetching https://github.com/example/dep\($0).git" }
        let failed = run(
            exitCode: 1,
            stdout: (["error: 'swift-numerics': Couldn’t check out revision ‘0c0290ff’:",
                      "    fatal: unable to read tree (0c0290ff)"] + progress).joined(separator: "\n"),
            elapsed: 15)

        let result = BuildChecker.createResult(run: failed, duration: .seconds(15))

        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["build-unparsed-failure"])
        let message = try #require(result.diagnostics.first?.message)
        #expect(message.hasPrefix("""
            `swift build --build-tests` exited 1 and nothing it printed is a diagnostic this \
            checker can parse. It was not stopped by its time budget.
              checker: build
              budget:  3600s — the first-run budget, because no successful run is recorded yet
              elapsed: 15s
              load:    1-minute load average 212.5 on 10 cores (21.3 per core)
              what the tool reported as an error, outside the lines quoted below:
                | error: 'swift-numerics': Couldn’t check out revision ‘0c0290ff’:
                | fatal: unable to read tree (0c0290ff)
              last 20 of 24 lines of output:
                | Fetching https://github.com/example/dep3.git
            """))
        #expect(result.diagnostics.first?.suggestedFix == """
            Rerun this checker alone: `quality-gate --check build`. For the whole transcript, \
            run `swift build --build-tests` in /work/pkg.
            """)
    }

    // MARK: - The checker, end to end, with nothing launched

    @Test("swift build runs under a budget derived from its history, not the runner's 600 seconds")
    func firstRunBudgetReachesTheTool() async throws {
        let root = try scratchPackage()
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort cleanup of a temporary fixture
        let seen = Launches()
        let checker = BuildChecker(launcher: launcher(
            answering: .init(stdout: "", stderr: kernelNote, exitCode: 124), elapsed: 3_601, seen: seen))
        var configuration = Configuration()
        configuration.projectRoot = root

        let result = try await checker.check(configuration: configuration)

        #expect(seen.timeouts == [3_600])
        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["build-timeout"])
        #expect(CheckerBudget.lastSuccess(named: "build", root: root.path) == nil)
    }

    @Test("A configured budget replaces the derived one, and a finished build records its duration")
    func configuredBudgetAndRecordedSuccess() async throws {
        let root = try scratchPackage()
        defer { try? FileManager.default.removeItem(at: root) } // silent: best-effort cleanup of a temporary fixture
        let seen = Launches()
        let checker = BuildChecker(launcher: launcher(
            answering: .init(stdout: "Build complete!\n", stderr: "", exitCode: 0), elapsed: 261, seen: seen))
        var configuration = Configuration(budgets: try CheckerBudgetsConfig(["build": 1_200]))
        configuration.projectRoot = root

        _ = try await checker.check(configuration: configuration)

        #expect(seen.timeouts == [1_200])
        #expect(CheckerBudget.lastSuccess(named: "build", root: root.path) == 261)
    }
}
