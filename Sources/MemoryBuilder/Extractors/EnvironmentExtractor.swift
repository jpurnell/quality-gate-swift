import Foundation

/// Extracts environment info (Swift version, platform).
public struct EnvironmentExtractor: MemoryExtractor, Sendable {
    /// Unique identifier for this extractor.
    public let id = "environment"

    /// Creates a new environment extractor.
    public init() {}

    /// Detects local platform, Swift version, and hardware, returning a reference memory entry.
    public func extract(
        projectRoot: String,
        guidelinesPath: String,
        globalClaudeMD: String?
    ) async throws -> [MemoryEntry] {
        var lines: [String] = []

        // Platform
        #if os(macOS)
        lines.append("**Platform:** macOS")
        #elseif os(Linux)
        lines.append("**Platform:** Linux")
        #else
        lines.append("**Platform:** Unknown")
        #endif

        // Swift version
        if let version = runCommand("/usr/bin/swift", args: ["--version"]) {
            // Extract just the version number from "Swift version 6.0.3 (swift-6.0.3-RELEASE)"
            if let range = version.range(of: #"Swift version (\S+)"#, options: .regularExpression) {
                lines.append("**Swift:** \(version[range])")
            } else {
                lines.append("**Swift:** \(version.components(separatedBy: "\n").first ?? version)")
            }
        }

        // CPU info
        #if os(macOS)
        if let chip = runCommand("/usr/sbin/sysctl", args: ["-n", "machdep.cpu.brand_string"]) {
            lines.append("**CPU:** \(chip)")
        }
        #endif

        guard !lines.isEmpty else { return [] }

        return [
            MemoryEntry(
                filename: "reference_environment.md",
                name: "Development Environment",
                description: "Local Swift version, platform, and hardware",
                type: "reference",
                body: lines.joined(separator: "\n")
            )
        ]
    }

    // MARK: - Helpers

    private func runCommand(_ executable: String, args: [String]) -> String? {
        let process = Process() // SAFETY: runs CLI tools (swift, git, xcodebuild) to detect environment info
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
