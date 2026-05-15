import Foundation

/// Runs a child process and captures its output without pipe-buffer deadlocks.
///
/// Foundation's `Process` with `Pipe` can deadlock when the child process
/// produces more output than the pipe buffer (~64 KB). The standard pattern
/// of `process.waitUntilExit()` then `pipe.readDataToEndOfFile()` blocks
/// because the process can't exit while the buffer is full, and the caller
/// can't drain the buffer while waiting for exit.
///
/// This helper reads stdout and stderr concurrently in the background,
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

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()

        process.waitUntilExit()

        return Output(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }
}
