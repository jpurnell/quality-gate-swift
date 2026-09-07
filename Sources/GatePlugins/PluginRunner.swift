import Foundation
#if canImport(os)
import os
#endif
import Synchronization
import QualityGateCore

/// Spawns Tier-2 plugin executables and speaks the contract (Phase 4b).
///
/// Every failure mode — timeout, non-zero exit, malformed output, unknown
/// contract version — becomes a value the caller turns into a
/// `plugin-error` diagnostic. The runner itself never throws past its
/// boundary and never crashes the gate.
public enum PluginRunner {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "PluginRunner")


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
        // The skip *is* reported upstream as a note. What the note cannot say is why the
        // descriptor would not decode, which is what the plugin author needs.
        do {
            return try JSONDecoder().decode(PluginDescriptor.self, from: data)
        } catch {
            Self.logger.warning(
                "plugin descriptor could not be decoded: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
            logger.warning("plugin request encoding failed: \(error.localizedDescription, privacy: .public)")
            return .launchFailed(reason: "request encoding failed: \(error.localizedDescription)")
        }
        // The plugin runs *in* the root it is asked about: a plugin that resolves
        // relative paths gets the tree the request names, not wherever the gate
        // happened to be invoked.
        return invoke(
            executable: executable, arguments: ["check"],
            stdin: payload, timeoutSeconds: timeoutSeconds,
            currentDirectory: request.projectRoot)
    }

    /// The one spawn path, delegated to the audited kernel.
    ///
    /// This used to spawn its own `Process` and carried three ways to hang, all of which read as
    /// careful code. It armed a watchdog that called `terminate()`, which bounds the *child* and
    /// not the *read*: a plugin whose child leaves a grandchild holding the inherited write end
    /// keeps the pipe open, so `readDataToEndOfFile()` never returned and the `.timedOut` result
    /// it had just recorded was never reached — the timeout fired into a line that could not run.
    /// It also wrote its stdin payload inline, which blocks past the pipe buffer against a plugin
    /// that reads to EOF before replying.
    ///
    /// None of that was carelessness; it had the most deliberate hang-handling in the codebase.
    /// It is the reason the rule is containment rather than judgement: the wrong version looked
    /// bounded locally and the right version does not.
    private static func invoke(
        executable: String,
        arguments: [String],
        stdin: Data?,
        timeoutSeconds: Int,
        currentDirectory: String? = nil
    ) -> Outcome {
        let result: ProcessRunner.Output
        do {
            result = try ProcessRunner.run(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                stdin: stdin,
                mergeStderr: true,
                timeout: TimeInterval(timeoutSeconds))
        } catch {
            logger.warning("plugin launch failed: \(error.localizedDescription, privacy: .public)")
            return .launchFailed(reason: error.localizedDescription)
        }

        // 124 is the runner's timeout code, by the shell convention. Distinguishing it from a
        // plugin's own exit status is why the runner names the timeout rather than throwing.
        if result.exitCode == 124 {
            return .timedOut(seconds: timeoutSeconds)
        }
        guard result.exitCode == 0 else {
            return .failed(exitCode: result.exitCode, output: result.stdout)
        }
        return .responded(Data(result.stdout.utf8))
    }
}
