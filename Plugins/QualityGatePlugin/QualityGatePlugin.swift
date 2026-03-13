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

        // Forward output to the console
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        // Print the output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if let output = String(data: outputData, encoding: .utf8), !output.isEmpty {
            print(output, terminator: "")
        }
        if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
            print(errorOutput, terminator: "")
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
