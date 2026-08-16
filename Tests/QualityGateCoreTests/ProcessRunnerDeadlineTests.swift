import Foundation
import Testing
@testable import QualityGateCore

/// Tests that `ProcessRunner` cannot wait forever.
///
/// Observed 2026-08-16: a survey run against `Alamofire` sat for **46 minutes** producing
/// nothing. `sample` showed the main thread parked and a `quality-gate.stderr-reader` thread
/// blocked in `readDataToEndOfFile()`, with no child process alive.
///
/// The runner already guards the classic 64 KB pipe-buffer deadlock — it reads stdout and
/// stderr concurrently, and its doc comment explains why. This is a different failure with the
/// same symptom: `readDataToEndOfFile()` returns at EOF, and EOF arrives only when *every*
/// write end closes. A child that spawns a grandchild passes the inherited descriptors along,
/// so the child can exit while the grandchild holds the pipe open — and the read never returns.
/// SwiftPM does this routinely.
///
/// This matters well beyond the survey: `ProcessRunner` is the shared path for `BuildChecker`,
/// `TestRunner`, `DocLinter`, `UnreachableCodeAuditor` and a dozen more, so a hang here hangs
/// the pre-commit hook — which already takes ~8 minutes, making an infinite hang nearly
/// indistinguishable from a slow run.
@Suite("ProcessRunner deadline")
struct ProcessRunnerDeadlineTests {

    /// **The reproduction**, and a correction to the first analysis of it.
    ///
    /// The child exits immediately; the grandchild inherits the pipe and holds it for 30
    /// seconds. Closing the *parent's* copy of the write end — the first fix attempted — does
    /// not help: the grandchild has its own inherited copy, and nothing this process closes can
    /// force that one shut. The grandchild case is therefore **bounded by the deadline, not
    /// eliminated by descriptor hygiene**.
    ///
    /// What must hold: the run ends at the deadline rather than after 30s (or forever), and the
    /// output the child *did* produce survives. That second half is why the readers drain
    /// incrementally — `readDataToEndOfFile()` returns everything only at EOF, so a timed-out
    /// run using it reports nothing at all, discarding the very evidence that explains the hang.
    @Test("a grandchild holding the pipe is bounded by the deadline", .timeLimit(.minutes(1)))
    func grandchildHoldingPipeIsBounded() throws {
        let out = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo hello; sleep 30 & exit 0"],
            timeout: 3
        )

        // Exit 124 is deterministic proof the deadline fired — asserting on measured elapsed
        // time would flake under load, and the suite's `.timeLimit` already fails a real hang.
        #expect(out.exitCode == 124, "expected the deadline to bound the grandchild")
        // And the output the child produced before exiting is not lost.
        #expect(out.stdout.contains("hello"), "partial output was discarded: \(out.stdout.debugDescription)")
    }

    /// A process that simply never finishes must be bounded, whatever the reason. Closing
    /// descriptors does not help here — this is what the deadline is for.
    @Test("a hanging child is terminated at the deadline", .timeLimit(.minutes(1)))
    func hangingChildIsTerminated() throws {
        let out = try ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 60"], timeout: 2)

        #expect(out.exitCode == 124, "a timed-out run must report the conventional timeout code")
        #expect(out.stderr.lowercased().contains("timed out"),
                "the timeout must be named, not silent: \(out.stderr)")
    }

    /// The guard on the existing behaviour. The concurrent-read fix for the 64 KB buffer
    /// deadlock must not regress — a process writing heavily to both streams still returns
    /// complete output.
    @Test("large output on both streams is still captured in full", .timeLimit(.minutes(1)))
    func largeOutputStillWorks() throws {
        let out = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "for i in $(seq 1 5000); do echo \"out $i\"; echo \"err $i\" >&2; done"],
            timeout: 60
        )
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("out 5000"), "stdout truncated")
        #expect(out.stderr.contains("err 5000"), "stderr truncated")
    }

    /// A fast process must not pay for the deadline machinery.
    @Test("a fast process returns promptly and correctly", .timeLimit(.minutes(1)))
    func fastProcessUnaffected() throws {
        let out = try ProcessRunner.run("/bin/echo", arguments: ["quick"], timeout: 30)
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("quick"))
    }

    /// Merged-stderr callers take the same path and must also be bounded.
    @Test("mergeStderr is bounded too", .timeLimit(.minutes(1)))
    func mergedStderrIsBounded() throws {
        let out = try ProcessRunner.run(
            "/bin/sh", arguments: ["-c", "sleep 60"], mergeStderr: true, timeout: 2)
        #expect(out.exitCode == 124)
    }
}
