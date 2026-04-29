import Foundation

/// Extracts project profile from Package.swift.
public struct ProjectProfileExtractor: MemoryExtractor, Sendable {
    /// Unique identifier for this extractor.
    public let id = "projectProfile"

    /// Creates a new project profile extractor.
    public init() {}

    /// Parses Package.swift and returns a memory entry summarizing targets and dependencies.
    public func extract(
        projectRoot: String,
        guidelinesPath: String,
        globalClaudeMD: String?
    ) async throws -> [MemoryEntry] {
        let packagePath = (projectRoot as NSString).appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: packagePath) else { return [] } // SAFETY: reads Package.swift from project root

        let source = try String(contentsOfFile: packagePath, encoding: .utf8)

        let projectName = extractPackageName(from: source) ?? "Unknown"
        let toolsVersion = extractToolsVersion(from: source)
        let targets = extractTargets(from: source)
        let testTargets = extractTestTargets(from: source)
        let dependencies = extractDependencies(from: source)

        var lines: [String] = []
        lines.append("**Project:** \(projectName)")
        if let version = toolsVersion {
            lines.append("**Swift Tools Version:** \(version)")
        }
        if !targets.isEmpty {
            lines.append("")
            lines.append("**Targets:** \(targets.joined(separator: ", "))")
        }
        if !testTargets.isEmpty {
            lines.append("**Test Targets:** \(testTargets.joined(separator: ", "))")
        }
        if !dependencies.isEmpty {
            lines.append("")
            lines.append("**Dependencies:**")
            for dep in dependencies {
                lines.append("- \(dep)")
            }
        }

        return [
            MemoryEntry(
                filename: "project_profile.md",
                name: "Project Profile",
                description: "\(projectName) — Swift package structure and dependencies",
                type: "project",
                body: lines.joined(separator: "\n")
            )
        ]
    }

    // MARK: - Parsing helpers

    /// Extracts the package name from `Package(name: "Foo"`.
    private func extractPackageName(from source: String) -> String? {
        // Match: name: "ProjectName"
        guard let range = source.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let match = source[range]
        // Extract the quoted value
        guard let quoteStart = match.firstIndex(of: "\""),
              let quoteEnd = match[match.index(after: quoteStart)...].firstIndex(of: "\"") else {
            return nil
        }
        return String(match[match.index(after: quoteStart)..<quoteEnd])
    }

    /// Extracts the swift-tools-version comment.
    private func extractToolsVersion(from source: String) -> String? {
        guard let range = source.range(
            of: #"swift-tools-version:\s*(\S+)"#,
            options: .regularExpression
        ) else { return nil }
        let match = String(source[range])
        return match.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
    }

    /// Extracts .target(name:) entries.
    private func extractTargets(from source: String) -> [String] {
        extractNamedEntries(from: source, pattern: #"\.target\s*\(\s*name:\s*"([^"]+)""#)
    }

    /// Extracts .testTarget(name:) entries.
    private func extractTestTargets(from source: String) -> [String] {
        extractNamedEntries(from: source, pattern: #"\.testTarget\s*\(\s*name:\s*"([^"]+)""#)
    }

    /// Extracts dependency package names from .package(url:) entries.
    private func extractDependencies(from source: String) -> [String] {
        var deps: [String] = []
        let pattern = #"\.package\s*\(\s*url:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let url = nsSource.substring(with: match.range(at: 1))
            // Extract repo name from URL: "https://github.com/jpsim/Yams.git" → "Yams"
            let name = (url as NSString).lastPathComponent
                .replacingOccurrences(of: ".git", with: "")
            deps.append(name)
        }
        return deps
    }

    /// Generic helper to extract name parameters from SPM target declarations.
    private func extractNamedEntries(from source: String, pattern: String) -> [String] {
        var results: [String] = []
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            results.append(nsSource.substring(with: match.range(at: 1)))
        }
        return results
    }
}
