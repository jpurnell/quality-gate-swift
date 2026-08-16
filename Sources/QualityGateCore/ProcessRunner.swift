import Foundation
import Synchronization

/// Accumulates a reader thread's output.
///
/// A plain reference type with a lock, rather than `Mutex<Data>`: the readers run on escaping
/// closures, and a noncopyable value captured there does not reliably reach the same instance —
/// appends went to a copy and the captured output came back empty. A class has one identity,
/// which is the property this needs.
// Justification: `data` is only ever touched under `lock`, and the class holds no other state.
private final class OutputBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// Runs a child process and captures its output without pipe-buffer deadlocks.
///
/// Foundation's `Process` with `Pipe` can deadlock when the child process
/// produces more output than the pipe buffer (~64 KB). Reading stdout then
/// stderr sequentially blocks if the child fills stderr before closing
/// stdout — the child blocks on stderr write while the caller blocks
/// waiting for stdout EOF.
///
/// This helper reads stdout and stderr concurrently on background threads,
/// then waits for the process to finish.
public enum ProcessRunner: Sendable {

    /// Result of running a process.
    public struct Output: Sendable {
        /// Combined or individual stdout content.
        public let stdout: String
        /// stderr content (empty if merged with stdout).
        public let stderr: String
        /// Process exit code.
        public let exitCode: Int32
    }

    /// Runs a process with the given executable and arguments.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the executable.
    ///   - arguments: Command-line arguments.
    ///   - currentDirectory: Working directory (nil for inherited).
    ///   - environment: Full environment for the child (nil inherits the parent's).
    ///     Pass an explicit environment to isolate a child from inherited state —
    ///     e.g. scrubbing `GIT_*` vars so a `git` subprocess ignores an ambient
    ///     repository set by a git hook.
    ///   - mergeStderr: If true, stderr is merged into stdout.
    ///   - timeout: Wall-clock budget. On expiry the child is terminated, whatever output
    ///     arrived is returned, and `exitCode` is non-zero with the timeout named in `stderr` —
    ///     **a timeout is a finding, not a crash**, and the caller decides what it means. The
    ///     default is generous because a cold build of a large package legitimately takes
    ///     minutes; what it rules out is *forever*.
    /// - Returns: The captured output and exit code.
    public static func run(
        _ executablePath: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        mergeStderr: Bool = false,
        timeout: TimeInterval = 600
    ) throws -> Output {
        let process = Process() // SAFETY: callers pass hardcoded executable paths
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let dir = currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        let stderrPipe: Pipe?
        if mergeStderr {
            process.standardError = stdoutPipe
            stderrPipe = nil
        } else {
            let p = Pipe()
            process.standardError = p
            stderrPipe = p
        }

        try process.run()

        // Close *our* copies of the write ends, now that the child owns them.
        //
        // `readDataToEndOfFile()` returns at EOF, and EOF arrives only when every write end is
        // closed — including the one this process still holds. Leaving it open means a child
        // that spawns a grandchild (SwiftPM does this routinely: build servers, test helpers,
        // index daemons) can exit while the descriptor lives on, and the read waits forever.
        // Observed 2026-08-16 as a 46-minute silent hang.
        try? stdoutPipe.fileHandleForWriting.close()  // silent: already closed if the child exited first, which is not an error
        if let stderrPipe {
            try? stderrPipe.fileHandleForWriting.close()  // silent: same
        }

        // Read stdout and stderr concurrently to prevent pipe-buffer deadlock.
        // If either pipe's buffer fills (~64 KB) while the other is being read
        // sequentially, the child blocks on write and the caller blocks on read.
        let stdoutBox = OutputBox()
        let stderrBox = OutputBox()
        let readers = DispatchGroup()

        // Read incrementally rather than with `readDataToEndOfFile()`.
        //
        // That call accumulates internally and hands everything back at EOF, so a run that
        // times out returns *nothing* — including output the child had already produced and
        // which is usually the most useful evidence about why it hung. Appending each chunk as
        // it arrives means a terminated run still reports what it managed to say.
        // Readers run on dedicated `Thread`s, not on a dispatch queue.
        //
        // `readers.wait()` below blocks the calling thread. If the readers were queued onto
        // libdispatch's worker pool, that blocked thread would be *from the same pool* — and
        // under load (a parallel test suite, or several checkers running at once) the pool can
        // starve before the reader blocks are ever scheduled. The symptom is indistinguishable
        // from the pipe deadlock this helper exists to prevent: a run that produces no output
        // and ends exactly at its deadline. Measured while fixing that very bug.
        readers.enter()
        Thread {
            let handle = stdoutPipe.fileHandleForReading
            // silent: a closed handle ends the drain — the intended exit path on timeout.
            while let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? nil, !chunk.isEmpty {
                stdoutBox.append(chunk)
            }
            readers.leave()
        }.start()

        if let stderrPipe {
            readers.enter()
            Thread {
                let handle = stderrPipe.fileHandleForReading
                // silent: a closed handle ends the drain — how a timed-out run stops this reader.
                while let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? nil, !chunk.isEmpty {
                    stderrBox.append(chunk)
                }
                readers.leave()
            }.start()
        }

        // The deadline. Descriptor hygiene above fixes the cause we found; this bounds the ones
        // we have not — a child blocked on a lock, a network read with no timeout of its own, a
        // prompt waiting on stdin it will never get.
        var timedOut = false
        if readers.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            // Give the child a moment to die and release the descriptors, then stop waiting on
            // the readers regardless: a deadline that can itself hang is not a deadline.
            _ = readers.wait(timeout: .now() + 5)
        }

        if !timedOut {
            process.waitUntilExit()
        }

        if timedOut {
            // Unblock the readers *before* snapshotting. The child is gone, but a grandchild may
            // still hold a copy of the write end — nothing this process closes can force that
            // one shut, so a reader can sit on a pipe that never reaches EOF while data it has
            // already been sent waits unread in the buffer. Closing the read end ends the
            // blocked read, and the reader then drains what was buffered.
            //
            // Ordering is the whole point: snapshotting first returns an empty result and
            // discards exactly the output that explains the hang.
            try? stdoutPipe.fileHandleForReading.close()  // silent: unblocking a reader; a close error changes nothing
            try? stderrPipe?.fileHandleForReading.close()  // silent: same
            _ = readers.wait(timeout: .now() + 2)
        }

        let stdoutData = stdoutBox.snapshot()
        let stderrData = stderrBox.snapshot()
        let capturedStderr = String(data: stderrData, encoding: .utf8) ?? ""

        if timedOut {
            let seconds = Int(timeout)
            return Output(
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: capturedStderr
                    + "\nquality-gate: `\(executablePath)` timed out after \(seconds)s and was terminated.",
                // 124 is the conventional timeout exit code (GNU `timeout`), so a caller
                // reading only the code can still tell this apart from an ordinary failure.
                exitCode: 124
            )
        }

        return Output(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: capturedStderr,
            exitCode: process.terminationStatus
        )
    }
}
