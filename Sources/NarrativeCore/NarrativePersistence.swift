import Foundation

/// Persists narrative output to the corpus: one document per project (the rule),
/// plus the portfolio narrative. Per-project docs land under `<root>/projects/`.
public struct NarrativePersistence: Sendable {
    /// Creates the persistence helper.
    public init() {}

    /// Writes each project's narrative to `<pulseDir>/projects/<safeID>.md` and
    /// returns the written paths, in project-ID order. Creates the directory if
    /// needed.
    @discardableResult
    public func writePerProject(_ narratives: [ProjectNarrative], pulseDir: String) throws -> [String] {
        let projectsDir = (pulseDir as NSString).appendingPathComponent("projects")
        try FileManager.default.createDirectory(atPath: projectsDir, withIntermediateDirectories: true)
        var paths: [String] = []
        for narrative in narratives.sorted(by: { $0.projectID < $1.projectID }) {
            let file = (projectsDir as NSString).appendingPathComponent("\(Self.safeName(narrative.projectID)).md")
            let body = "# \(narrative.projectID)\n\n\(narrative.text)\n"
            try body.write(toFile: file, atomically: true, encoding: .utf8)
            paths.append(file)
        }
        return paths
    }

    /// Writes the portfolio narrative body to `path`, creating parent dirs.
    public func writePortfolio(_ text: String, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Makes a project ID safe for use as a filename — no path separators can
    /// escape the projects directory.
    static func safeName(_ id: String) -> String {
        var out = ""
        out.reserveCapacity(id.count)
        for scalar in id.unicodeScalars {
            switch scalar {
            case "/", "\\", ":", "\0":
                out.append("_")
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out.isEmpty ? "_" : out
    }
}
