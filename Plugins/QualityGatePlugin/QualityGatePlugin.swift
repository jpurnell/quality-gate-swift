import Foundation
import PackagePlugin

/// SPM Command Plugin for running quality-gate checks.
///
/// Usage: `swift package quality-gate [arguments]`
@main
struct QualityGatePlugin: CommandPlugin {

    func performCommand(
        context: PluginContext,
        arguments: [String]
    ) async throws {
        // Build the quality-gate executable first
        let buildResult = try packageManager.build(
            .product("quality-gate"),
            parameters: .init()
        )

        guard buildResult.succeeded else {
            print("Failed to build quality-gate")
            for line in buildResult.logText.split(separator: "\n").suffix(20) {
                print(line)
            }
            throw PluginError.buildFailed
        }

        // Find the built executable
        guard let executable = buildResult.builtArtifacts.first(where: {
            $0.kind == .executable && $0.url.lastPathComponent == "quality-gate"
        }) else {
            throw PluginError.executableNotFound
        }

        // Run the quality-gate tool with the provided arguments
        let process = Process()
        process.executableURL = executable.url
        process.arguments = arguments
        process.currentDirectoryURL = context.package.directoryURL

        // One pipe for both streams, drained before waiting.
        //
        // This plugin spawns the gate on a consumer's build, and a full run produces far more
        // than the ~64 KB pipe buffer holds. The previous ordering waited for exit and only then
        // read, so the child blocked writing while this process blocked waiting — a deadlock on
        // any project large enough to matter, in the one code path shipped to other people.
        //
        // Both streams share a pipe deliberately. Draining two pipes in sequence reintroduces the
        // same deadlock on whichever is read second, and draining them concurrently is not
        // available here: `performCommand` is async, where `DispatchGroup.wait()` is unavailable,
        // and `Pipe` is not `Sendable` so it cannot cross into a detached task. One pipe needs no
        // concurrency at all, and since both streams were only ever printed to stdout in
        // sequence, merging them also preserves the order the tool actually emitted them in.
        let combinedPipe = Pipe()
        process.standardOutput = combinedPipe
        process.standardError = combinedPipe

        try process.run()

        var combined = Data()
        // silent: a closed handle ends the drain — the normal exit path when the child finishes.
        while let chunk = (try? combinedPipe.fileHandleForReading.read(upToCount: 64 * 1024)) ?? nil,
              !chunk.isEmpty {
            combined.append(chunk)
        }
        process.waitUntilExit()

        if let output = String(data: combined, encoding: .utf8), !output.isEmpty {
            print(output, terminator: "")
        }

        // Exit with the same code as the quality-gate tool
        if process.terminationStatus != 0 {
            throw PluginError.toolFailed(exitCode: process.terminationStatus)
        }
    }
}

enum PluginError: Error, CustomStringConvertible {
    case buildFailed
    case executableNotFound
    case toolFailed(exitCode: Int32)

    var description: String {
        switch self {
        case .buildFailed:
            return "Failed to build quality-gate executable"
        case .executableNotFound:
            return "Could not find built quality-gate executable"
        case .toolFailed(let exitCode):
            return "Quality gate check failed with exit code \(exitCode)"
        }
    }
}
