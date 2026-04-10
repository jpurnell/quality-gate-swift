import Foundation

/// Extracts module architecture from Package.swift dependency graph.
public struct ArchitectureExtractor: MemoryExtractor, Sendable {
    public let id = "architecture"

    public init() {}

    public func extract(
        projectRoot: String,
        guidelinesPath: String,
        globalClaudeMD: String?
    ) async throws -> [MemoryEntry] {
        let packagePath = (projectRoot as NSString).appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: packagePath) else { return [] }

        let source = try String(contentsOfFile: packagePath, encoding: .utf8)
        let targets = parseTargetsWithDeps(from: source)

        guard !targets.isEmpty else { return [] }

        var lines: [String] = []
        lines.append("**Module dependency graph:**\n")
        for target in targets.sorted(by: { $0.name < $1.name }) {
            if target.deps.isEmpty {
                lines.append("- **\(target.name)** (no internal deps)")
            } else {
                lines.append("- **\(target.name)** → \(target.deps.joined(separator: ", "))")
            }
        }

        return [
            MemoryEntry(
                filename: "project_architecture.md",
                name: "Module Architecture",
                description: "Module dependency graph (\(targets.count) targets)",
                type: "project",
                body: lines.joined(separator: "\n")
            )
        ]
    }

    // MARK: - Parsing

    private struct TargetInfo {
        let name: String
        let deps: [String]
    }

    /// Parse target declarations and their internal dependencies.
    private func parseTargetsWithDeps(from source: String) -> [TargetInfo] {
        var results: [TargetInfo] = []

        // Match .target(name: "X", dependencies: [...]) and .executableTarget(...)
        let targetPattern = #"\.(target|executableTarget|testTarget)\s*\(\s*name:\s*"([^"]+)"([^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: targetPattern, options: .dotMatchesLineSeparators) else {
            return []
        }

        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let name = nsSource.substring(with: match.range(at: 2))

            // Extract internal dependencies (quoted strings in dependencies: [...])
            var deps: [String] = []
            if match.numberOfRanges >= 4 {
                let rest = nsSource.substring(with: match.range(at: 3))
                if let depsRange = rest.range(of: #"dependencies:\s*\["#, options: .regularExpression) {
                    let afterDeps = rest[depsRange.upperBound...]
                    // Find simple string deps like "CoreModule"
                    let depPattern = #""([^"]+)""#
                    if let depRegex = try? NSRegularExpression(pattern: depPattern) {
                        let nsRest = String(afterDeps) as NSString
                        let depMatches = depRegex.matches(
                            in: String(afterDeps),
                            range: NSRange(location: 0, length: nsRest.length)
                        )
                        for depMatch in depMatches {
                            guard depMatch.numberOfRanges >= 2 else { continue }
                            let dep = nsRest.substring(with: depMatch.range(at: 1))
                            deps.append(dep)
                        }
                    }
                }
            }

            results.append(TargetInfo(name: name, deps: deps))
        }

        return results
    }
}
