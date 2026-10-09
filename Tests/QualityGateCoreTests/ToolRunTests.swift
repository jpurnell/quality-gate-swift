import Foundation
import Testing
@testable import QualityGateCore

// A checker that launches a build tool can stop for two reasons that are not findings about
// the source: the tool was terminated at its time budget, or it failed in a shape no parser
// recognised. Both used to be reported as something else — a signing warning, a failure with
// no diagnostic, a checker error at 0 ms — and under a load average in the hundreds that cost
// whole afternoons of retries. These tests fix what each one says, to the character.

/// A launcher that never starts a process: it answers with a canned output and advances the
/// injected clock, so every figure in the message is one the test chose.
private func launcher(
    answering output: ToolLauncher.Output,
    taking elapsed: TimeInterval,
    load: MachineLoad?
) -> ToolLauncher {
    let clock = SteppingClock(step: elapsed)
    return ToolLauncher(
        launch: { _ in output },
        monotonicSeconds: { clock.next() },
        load: { load })
}

/// A clock that advances by a fixed step each time it is read.
// Justification: `reading` is only touched under `lock`; the class holds no other state.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var reading: TimeInterval = 1_000
    private let step: TimeInterval

    init(step: TimeInterval) { self.step = step }

    func next() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let value = reading
        reading += step
        return value
    }
}

private let request = ToolLauncher.Request(
    checkerId: "test",
    executable: "/usr/bin/swift",
    arguments: ["test", "--parallel"],
    directory: "/work/pkg",
    environment: nil,
    budget: CheckerBudget.Allowance(checkerId: "test", seconds: 900, source: .lastSuccess(212)))

private let kernelNote = "\nprocess-kernel: `/usr/bin/swift` timed out after 900s and was terminated."

@Suite("A tool run that was stopped at its budget, or failed without saying why")
struct ToolRunTests {

    // MARK: - What a run records

    @Test("A run records the command, the budget, the elapsed time and the load it ended under")
    func runRecordsItsFacts() throws {
        let load = MachineLoad(oneMinute: 187.4, activeProcessors: 10)
        let run = try launcher(
            answering: .init(stdout: "Compiling\n", stderr: "", exitCode: 0), taking: 42, load: load
        ).run(request)

        #expect(run.checkerId == "test")
        #expect(run.command == "swift test --parallel")
        #expect(run.directory == "/work/pkg")
        #expect(run.exitCode == 0)
        #expect(run.elapsed == 42)
        #expect(run.budget.seconds == 900)
        #expect(run.load == load)
        #expect(run.expired == false)
    }

    @Test("The launcher hands the kernel the budget it was given, not a default")
    func launcherPassesTheBudget() throws {
        let seen = SeenTimeout()
        let launcher = ToolLauncher(
            launch: { invocation in
                seen.record(invocation.timeout)
                return .init(stdout: "", stderr: "", exitCode: 0)
            },
            monotonicSeconds: { 0 },
            load: { nil })
        _ = try launcher.run(request)
        #expect(seen.value == 900)
    }

    // MARK: - Expiry is recognised

    @Test("Exit 124 is an expiry even when the kernel's note was lost")
    func exitCodeAloneIsExpiry() throws {
        let run = try launcher(
            answering: .init(stdout: "", stderr: "", exitCode: 124), taking: 900, load: nil
        ).run(request)
        #expect(run.expired)
    }

    @Test("The kernel's note is an expiry even when something rewrote the exit code")
    func kernelNoteAloneIsExpiry() throws {
        let run = try launcher(
            answering: .init(stdout: "", stderr: kernelNote, exitCode: 1), taking: 900, load: nil
        ).run(request)
        #expect(run.expired)
    }

    @Test("An ordinary failure is not an expiry, even if the tool's output talks about timing out")
    func ordinaryFailureIsNotExpiry() throws {
        let run = try launcher(
            answering: .init(stdout: "error: the request timed out after 30s", stderr: "", exitCode: 1),
            taking: 12, load: nil
        ).run(request)
        #expect(run.expired == false)
    }

    // MARK: - What an expiry says

    @Test("An expiry names the checker, the budget, the elapsed time, the load and the last output")
    func expiryMessageIsExact() throws {
        let run = try launcher(
            answering: .init(
                stdout: "Building for debugging...\n[212/900] Compiling Alpha\n",
                stderr: "warning: slow\n" + kernelNote,
                exitCode: 124),
            taking: 905.4,
            load: MachineLoad(oneMinute: 187.4, activeProcessors: 10)
        ).run(request)

        let diagnostic = run.expiryDiagnostic()
        #expect(diagnostic.ruleId == "test-timeout")
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message == """
            `swift test --parallel` was stopped at its time budget and did not finish. This run \
            is incomplete: it is not a pass, and it is not a finding about the code.
              checker: test
              budget:  900s — three times the last successful run (212s), and never less than 900s
              elapsed: 905s
              load:    1-minute load average 187.4 on 10 cores (18.7 per core)
              last 3 lines of output:
                | Building for debugging...
                | [212/900] Compiling Alpha
                | warning: slow
            """)
        #expect(diagnostic.suggestedFix == """
            Rerun this checker alone, when the load is lower: `quality-gate --check test`. If it \
            needs longer than 900s on a quiet machine, raise its budget in .quality-gate.yml — \
            `budgets:` then `test: 1800` (seconds).
            """)
    }

    @Test("An expiry that printed nothing says so, and says when the load could not be read")
    func silentExpiryMessageIsExact() throws {
        let run = try launcher(
            answering: .init(stdout: "", stderr: kernelNote, exitCode: 124), taking: 900, load: nil
        ).run(request)

        #expect(run.expiryDiagnostic().message == """
            `swift test --parallel` was stopped at its time budget and did not finish. This run \
            is incomplete: it is not a pass, and it is not a finding about the code.
              checker: test
              budget:  900s — three times the last successful run (212s), and never less than 900s
              elapsed: 900s
              load:    not available on this platform
              the tool had printed nothing when it was stopped
            """)
    }

    @Test("Only the last twenty lines are quoted, and the count says how many there were")
    func tailIsBounded() throws {
        let lines = (1...45).map { "line \($0)" }.joined(separator: "\n")
        let run = try launcher(
            answering: .init(stdout: lines, stderr: kernelNote, exitCode: 124), taking: 900, load: nil
        ).run(request)

        let message = run.expiryDiagnostic().message
        #expect(message.contains("  last 20 of 45 lines of output:\n    | line 26\n"))
        #expect(message.hasSuffix("    | line 45"))
        #expect(!message.contains("| line 25\n"))
    }

    // MARK: - What an unparsed failure says

    @Test("An unparsed failure carries the same facts, says the budget was not the cause, and leads with the tool's own error lines")
    func unparsedFailureMessageIsExact() throws {
        let buildRequest = ToolLauncher.Request(
            checkerId: "build",
            executable: "/usr/bin/swift",
            arguments: ["build", "--build-tests"],
            directory: "/work/pkg",
            environment: nil,
            budget: CheckerBudget.Allowance(checkerId: "build", seconds: 3_600, source: .firstRun))
        let noise = (1...24).map { "Fetching dependency \($0)" }.joined(separator: "\n")
        let run = try launcher(
            answering: .init(
                stdout: "error: Couldn’t check out revision ‘abc123’:\n" + noise + "\n",
                stderr: "",
                exitCode: 1),
            taking: 15.2,
            load: MachineLoad(oneMinute: 6, activeProcessors: 12)
        ).run(buildRequest)

        let diagnostic = run.unparsedFailureDiagnostic(ruleId: "build-unparsed-failure")
        #expect(diagnostic.ruleId == "build-unparsed-failure")
        #expect(diagnostic.severity == .error)
        let tail = (5...24).map { "    | Fetching dependency \($0)" }.joined(separator: "\n")
        #expect(diagnostic.message == """
            `swift build --build-tests` exited 1 and nothing it printed is a diagnostic this \
            checker can parse. It was not stopped by its time budget.
              checker: build
              budget:  3600s — the first-run budget, because no successful run is recorded yet
              elapsed: 15s
              load:    1-minute load average 6.0 on 12 cores (0.5 per core)
              what the tool reported as an error, outside the lines quoted below:
                | error: Couldn’t check out revision ‘abc123’:
              last 20 of 25 lines of output:
            \(tail)
            """)
        #expect(diagnostic.suggestedFix == """
            Rerun this checker alone: `quality-gate --check build`. For the whole transcript, \
            run `swift build --build-tests` in /work/pkg.
            """)
    }

    @Test("Error lines already inside the quoted tail are not repeated above it")
    func errorLinesInTheTailAreNotRepeated() throws {
        let run = try launcher(
            answering: .init(stdout: "Planning build\nerror: no such module 'Foo'\n", stderr: "", exitCode: 1),
            taking: 3, load: nil
        ).run(request)

        let message = run.unparsedFailureDiagnostic(ruleId: "test-unparsed-failure").message
        #expect(!message.contains("what the tool reported as an error"))
        #expect(message.hasSuffix("""
              last 2 lines of output:
                | Planning build
                | error: no such module 'Foo'
            """))
    }

    @Test("Colour and hyperlink escapes are removed from quoted output")
    func escapesAreRemoved() throws {
        let run = try launcher(
            answering: .init(stdout: "\u{1B}[1;31merror: \u{1B}[0mbroken\n", stderr: "", exitCode: 1),
            taking: 3, load: nil
        ).run(request)
        #expect(run.unparsedFailureDiagnostic(ruleId: "test-unparsed-failure").message
            .hasSuffix("    | error: broken"))
    }

    // MARK: - A transcript without its run

    @Test("A transcript alone still yields the budget the kernel named, and admits what it lacks")
    func transcriptReconstruction() {
        let run = ToolRun(
            transcriptOf: "swift test", checkerId: "test",
            output: "Test started\nprocess-kernel: `/usr/bin/swift` timed out after 600s and was terminated.",
            exitCode: 124, elapsed: .seconds(600))
        #expect(run.expired)
        #expect(run.budget == CheckerBudget.Allowance(checkerId: "test", seconds: 600, source: .reportedByRunner))
        #expect(run.expiryDiagnostic().message == """
            `swift test` was stopped at its time budget and did not finish. This run is \
            incomplete: it is not a pass, and it is not a finding about the code.
              checker: test
              budget:  600s — as the process runner reported it
              elapsed: 600s
              load:    not available on this platform
              last 1 line of output:
                | Test started
            """)
    }

    @Test("A fractional budget in the kernel's note is read as written")
    func fractionalReportedBudget() {
        #expect(ToolRun.kernelReportedBudget(
            in: "process-kernel: `/bin/sleep` timed out after 0.5s and was terminated.")?
            .isEqual(to: 0.5) == true)
        #expect(ToolRun.kernelReportedBudget(in: "error: the request timed out after 30s") == nil)
    }

    // MARK: - Which diagnostics are expiries

    @Test("An expiry is recognised by its rule id, for every budgeted checker")
    func expiryRuleIds() {
        #expect(ToolRun.expiryRuleId(for: "build") == "build-timeout")
        #expect(ToolRun.expiryRuleId(for: "xcode-build") == "xcode-build-timeout")
        #expect(ToolRun.isExpiry(Diagnostic(severity: .error, message: "m", ruleId: "doc-lint-timeout")))
        #expect(!ToolRun.isExpiry(Diagnostic(severity: .error, message: "m", ruleId: "test-failure")))
        #expect(!ToolRun.isExpiry(Diagnostic(severity: .error, message: "m")))
    }

    // MARK: - The machine's load

    @Test("The load is described per core, and a machine reporting no cores is not divided by")
    func loadDescription() {
        #expect(MachineLoad(oneMinute: 24.02, activeProcessors: 12).description
            == "1-minute load average 24.0 on 12 cores (2.0 per core)")
        #expect(MachineLoad(oneMinute: 3.25, activeProcessors: 1).description
            == "1-minute load average 3.3 on 1 core (3.3 per core)")
        #expect(MachineLoad(oneMinute: 3.25, activeProcessors: 0).description
            == "1-minute load average 3.3")
    }

    @Test("The live reader returns a load this machine could have")
    func liveLoadIsPlausible() throws {
        let load = try #require(MachineLoad.current())
        #expect(load.oneMinute >= 0)
        #expect(load.oneMinute.isFinite)
        #expect(load.activeProcessors >= 1)
    }

    // MARK: - A real process, a real budget

    /// The one place a process must outlive a budget. 0.5 s is the smallest budget found
    /// reliable here: `/bin/sleep` needs only to have been spawned before the deadline, and it
    /// dies on the kernel's SIGTERM at once, so the run ends within a moment of the budget
    /// however loaded the machine is.
    @Test("A real process that outlives a real budget is reported as an expiry, with its output")
    func realProcessExpires() throws {
        let run = try ToolLauncher.live.run(ToolLauncher.Request(
            checkerId: "fixture",
            executable: "/bin/sh",
            arguments: ["-c", "echo started; exec /bin/sleep 30"],
            directory: nil,
            environment: nil,
            budget: CheckerBudget.Allowance(checkerId: "fixture", seconds: 0.5, source: .configured)))

        #expect(run.expired)
        #expect(run.exitCode == 124)
        let diagnostic = run.expiryDiagnostic()
        #expect(diagnostic.ruleId == "fixture-timeout")
        #expect(diagnostic.message.contains("  budget:  0.5s — set by `budgets.fixture` in .quality-gate.yml\n"))
        #expect(diagnostic.message.hasSuffix("  last 1 line of output:\n    | started"))
    }
}

/// Records the timeout a launcher was handed.
// Justification: `stored` is only touched under `lock`; the class holds no other state.
private final class SeenTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval?

    func record(_ timeout: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        stored = timeout
    }

    var value: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
