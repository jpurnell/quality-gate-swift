import Foundation

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
    ///   - mergeStderr: If true, stderr is merged into stdout.
    /// - Returns: The captured output and exit code.
    public static func run(
        _ executablePath: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        mergeStderr: Bool = false
    ) throws -> Output {
        let process = Process() // SAFETY: callers pass hardcoded executable paths
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let dir = currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
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

        // Read stdout and stderr concurrently to prevent pipe-buffer deadlock.
        // If either pipe's buffer fills (~64 KB) while the other is being read
        // sequentially, the child blocks on write and the caller blocks on read.
        var stderrData = Data()
        let stderrQueue = DispatchQueue(label: "quality-gate.stderr-reader")
        let stderrGroup = DispatchGroup()

        if let stderrPipe {
            stderrGroup.enter()
            stderrQueue.async {
                stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                stderrGroup.leave()
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stderrGroup.wait()

        process.waitUntilExit()

        return Output(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }
}
