import ArgumentParser // logging: CLI tool — print() is appropriate for user-facing output
import Foundation
import IJSAggregator

/// Generate or update a corpus manifest from telemetry project directories.
struct GenerateManifest: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "generate-manifest",
        abstract: "Generate or update a corpus manifest.yml from telemetry project directories."
    )

    @Option(name: .long, help: "Path to the IJS corpus directory (must contain telemetry/)")
    var corpusPath: String

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    func run() async throws {
        let fm = FileManager.default
        let telemetryDir = "\(corpusPath)/telemetry" // SAFETY: configured corpus path

        guard fm.fileExists(atPath: telemetryDir) else { // SAFETY: read-only check on configured path
            print("[generate-manifest] Error: No telemetry directory found at \(telemetryDir)") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        // Discover project directories under telemetry/
        let projectDirs: [String]
        do {
            projectDirs = try fm.contentsOfDirectory(atPath: telemetryDir) // SAFETY: reads configured corpus
                .filter { name in
                    var isDir: ObjCBool = false
                    let childPath = URL(fileURLWithPath: telemetryDir)
                        .appendingPathComponent(name).standardized.path
                    guard childPath.hasPrefix(
                        URL(fileURLWithPath: telemetryDir).standardized.path
                    ) else { return false } // SAFETY: reject path traversal
                    return fm.fileExists(
                        atPath: childPath,
                        isDirectory: &isDir
                    ) && isDir.boolValue
                }
                .sorted()
        } catch { // logging: error reported to user via print
            print("[generate-manifest] Error: Cannot read telemetry directory: \(error.localizedDescription)") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        guard !projectDirs.isEmpty else {
            print("[generate-manifest] Error: No project directories found in \(telemetryDir)") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        if verbose {
            print("[generate-manifest] Found \(projectDirs.count) project(s): \(projectDirs.joined(separator: ", "))") // logging: CLI verbose progress output
        }

        // Load existing manifest if present
        let manifestURL = URL(fileURLWithPath: "\(corpusPath)/manifest.yml")
        let existingManifest: CorpusManifest?
        if fm.fileExists(atPath: manifestURL.path) { // SAFETY: read-only check on configured path
            do {
                existingManifest = try CorpusManifest.load(from: manifestURL)
                if verbose {
                    print("[generate-manifest] Loaded existing manifest with \(existingManifest?.projects.count ?? 0) project(s) and \(existingManifest?.groups.count ?? 0) group(s)") // logging: CLI verbose progress output
                }
            } catch { // logging: error reported to user via print
                print("[generate-manifest] Warning: Cannot parse existing manifest, starting fresh: \(error.localizedDescription)") // logging: CLI user-facing output
                existingManifest = nil
            }
        } else {
            existingManifest = nil
            if verbose {
                print("[generate-manifest] No existing manifest found, creating new one") // logging: CLI verbose progress output
            }
        }

        // Build the output YAML
        let yaml = buildManifestYAML(
            projects: projectDirs,
            existingManifest: existingManifest
        )

        // Write manifest
        do {
            try yaml.write(toFile: manifestURL.path, atomically: true, encoding: .utf8)
        } catch { // logging: error reported to user via print
            print("[generate-manifest] Error: Cannot write manifest: \(error.localizedDescription)") // logging: CLI user-facing output
            throw ExitCode(1)
        }

        print("[generate-manifest] Wrote manifest to \(manifestURL.path)") // logging: CLI user-facing output
        print("[generate-manifest]   \(projectDirs.count) project(s)") // logging: CLI user-facing output
        let groupCount = existingManifest?.groups.count ?? 0
        print("[generate-manifest]   \(groupCount) group(s) preserved") // logging: CLI user-facing output
    }

    /// Builds a human-readable YAML string for the manifest.
    ///
    /// - Parameters:
    ///   - projects: Sorted list of project directory names.
    ///   - existingManifest: Previously loaded manifest to preserve entries and groups.
    /// - Returns: A YAML string ready to write to `manifest.yml`.
    func buildManifestYAML(projects: [String], existingManifest: CorpusManifest?) -> String {
        var lines: [String] = []
        lines.append("# Generated by quality-gate generate-manifest")
        lines.append("# Re-run to pick up new projects. Groups are preserved on regeneration.")
        lines.append("")
        lines.append("projects:")

        for project in projects.sorted() {
            let entry = existingManifest?.projects[project]
            let lifecycle = entry?.lifecycle.rawValue ?? "active"
            let changedAt = entry?.changedAt ?? Date()
            lines.append("  \(project):")
            lines.append("    lifecycle: \(lifecycle)")
            lines.append("    changedAt: \(iso8601String(changedAt))")
            if let reason = entry?.reason {
                lines.append("    reason: \"\(reason)\"")
            }
        }

        lines.append("")
        lines.append("groups:")

        let existingGroups = existingManifest?.groups ?? [:]
        if existingGroups.isEmpty {
            lines.append("  # Add groups here. Example:")
            lines.append("  # MyProject:")
            lines.append("  #   - MyProject")
            lines.append("  #   - MyProjectUI")
            lines.append("  #   - MyProjectTests")
        } else {
            for groupName in existingGroups.keys.sorted() {
                let members = existingGroups[groupName] ?? []
                lines.append("  \(groupName):")
                for member in members.sorted() {
                    lines.append("    - \(member)")
                }
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Formats a date as an ISO 8601 string.
    /// - Parameter date: The date to format.
    /// - Returns: An ISO 8601 formatted string.
    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
