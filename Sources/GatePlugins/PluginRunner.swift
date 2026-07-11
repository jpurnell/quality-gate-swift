import Foundation
import Synchronization
import QualityGateCore

/// Spawns Tier-2 plugin executables and speaks the contract (Phase 4b).
///
/// Every failure mode — timeout, non-zero exit, malformed output, unknown
/// contract version — becomes a value the caller turns into a
/// `plugin-error` diagnostic. The runner itself never throws past its
/// boundary and never crashes the gate.
public enum PluginRunner {

    /// The outcome of one plugin invocation.
    public enum Outcome: Sendable {
        /// The plugin responded with a decodable payload.
        case responded(Data)
        /// The plugin exceeded its wall-clock budget and was terminated.
        case timedOut(seconds: Int)
        /// The plugin exited non-zero; combined output attached.
        case failed(exitCode: Int32, output: String)
        /// The executable could not be launched.
        case launchFailed(reason: String)
    }

    /// Resolves a plugin's executable: explicit `run:` path, else
    /// `quality-gate-plugin-<name>` on PATH.
    ///
    /// - Parameters:
    ///   - config: The plugin entry.
    ///   - environment: Process environment (injectable for tests).
    /// - Returns: The executable path, or nil when nothing resolves.
    public static func resolveExecutable(
        for config: PluginConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let explicit = config.run {
            return FileManager.default.isExecutableFile(atPath: explicit) ? explicit : nil
        }
        let candidate = "quality-gate-plugin-\(config.name)"
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = (String(directory) as NSString).appendingPathComponent(candidate)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Runs `<plugin> contract` and decodes the descriptor.
    ///
    /// - Parameters:
    ///   - executable: The plugin binary.
    ///   - timeoutSeconds: Wall-clock budget.
    /// - Returns: The descriptor, or nil for any failure (callers note-and-skip).
    public static func describe(executable: String, timeoutSeconds: Int = 10) -> PluginDescriptor? {
        let outcome = invoke(
            executable: executable, arguments: ["contract"],
            stdin: nil, timeoutSeconds: timeoutSeconds)
        guard case .responded(let data) = outcome else { return nil }
        // silent: an undecodable descriptor is a skip-with-note upstream, not an error here
        return try? JSONDecoder().decode(PluginDescriptor.self, from: data)
    }

    /// Runs `<plugin> check` with the request on stdin.
    ///
    /// - Parameters:
    ///   - executable: The plugin binary.
    ///   - request: The contract request.
    ///   - timeoutSeconds: Wall-clock budget.
    /// - Returns: The raw outcome; decoding is the caller's step so a
    ///   garbage payload can carry its own diagnostic context.
    public static func check(
        executable: String,
        request: PluginCheckRequest,
        timeoutSeconds: Int
    ) -> Outcome {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            return .launchFailed(reason: "request encoding failed: \(error.localizedDescription)")
        }
        return invoke(
            executable: executable, arguments: ["check"],
            stdin: payload, timeoutSeconds: timeoutSeconds)
    }

    /// The one spawn path: stdin payload, drained pipes, wall-clock timeout.
    private static func invoke(
        executable: String,
        arguments: [String],
        stdin: Data?,
        timeoutSeconds: Int
    ) -> Outcome {
        let process = Process() // SAFETY: executable resolved from explicit config or PATH convention
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        do {
            try process.run()
        } catch {
            return .launchFailed(reason: error.localizedDescription)
        }

        if let stdin {
            stdinPipe.fileHandleForWriting.write(stdin)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // Watchdog: terminate on budget exhaustion. The main thread drains
        // stdout (before waiting — the 64 KB pipe-deadlock rule), so the
        // watchdog is a timer, not a reader.
        let timedOutFlag = Mutex(false)
        let watchdog = DispatchWorkItem {
            timedOutFlag.withLock { $0 = true }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(timeoutSeconds), execute: watchdog)

        let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if timedOutFlag.withLock({ $0 }) {
            return .timedOut(seconds: timeoutSeconds)
        }
        guard process.terminationStatus == 0 else {
            return .failed(
                exitCode: process.terminationStatus,
                output: String(decoding: output, as: UTF8.self))
        }
        return .responded(output)
    }
}
