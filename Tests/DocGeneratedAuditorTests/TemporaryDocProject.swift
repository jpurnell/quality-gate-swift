import Foundation
import QualityGateCore

/// A throwaway project root with the three documents this checker governs.
///
/// Every file is written explicitly, so a test's fixture is visible in the test rather than
/// inherited from whatever the repository happens to contain today.
enum TemporaryDocProject {

    /// Creates a project root and returns its URL. The caller removes it.
    ///
    /// - Parameters:
    ///   - readme: `README.md` contents, or `nil` to omit the file.
    ///   - changelog: `CHANGELOG.md` contents, or `nil` to omit the file.
    ///   - masterPlan: `project/master_plan.md` contents, or `nil` to omit the file.
    ///   - packageManifest: `Package.swift` contents, or `nil` to omit the file.
    ///   - extras: Additional files, keyed by path relative to the root.
    static func make(
        readme: String? = nil,
        changelog: String? = nil,
        masterPlan: String? = nil,
        packageManifest: String? = nil,
        extras: [String: String] = [:]
    ) throws -> URL {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("doc-generated-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        var files: [String: String] = extras
        if let readme { files["README.md"] = readme }
        if let changelog { files["CHANGELOG.md"] = changelog }
        if let masterPlan { files["project/master_plan.md"] = masterPlan }
        if let packageManifest { files["Package.swift"] = packageManifest }

        for (relative, contents) in files {
            let url = root.appendingPathComponent(relative)
            try manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// A configuration pointing at the fixture's master plan, as this repository's own
    /// `.quality-gate.yml` does.
    static func configuration(
        docGenerated: DocGeneratedConfig = DocGeneratedConfig(),
        excludePatterns: [String] = []
    ) -> Configuration {
        Configuration(
            excludePatterns: excludePatterns,
            status: StatusAuditorConfig(
                guidelinesPath: ".", masterPlanPath: "project/master_plan.md"),
            docGenerated: docGenerated)
    }
}
