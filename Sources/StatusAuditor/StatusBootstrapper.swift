import Foundation
import QualityGateCore

/// Generates a complete Master Plan from actual project state.
///
/// Used when a project adopts quality-gate-swift and needs initial status
/// documentation, or when drift is so severe that patching would be worse
/// than regenerating.
///
/// Generated content includes `<!-- TODO -->` placeholders where human-authored
/// prose should be added.
public enum StatusBootstrapper {

    /// Generate a Master Plan from actual project state.
    ///
    /// - Parameters:
    ///   - projectRoot: Root directory of the Swift project.
    ///   - configuration: Project configuration.
    /// - Returns: Complete Master Plan markdown content.
    public static func generate(
        projectRoot: String,
        configuration: Configuration
    ) -> String {
        let sourcesPath = (projectRoot as NSString).appendingPathComponent("Sources")
        let testsPath = (projectRoot as NSString).appendingPathComponent("Tests")
        let packagePath = (projectRoot as NSString).appendingPathComponent("Package.swift")

        let modules = ProjectStateCollector.collectModuleStates(
            sourcesPath: sourcesPath,
            testsPath: testsPath,
            packagePath: packagePath
        )

        // Parse package name
        let packageName = parsePackageName(at: packagePath)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let today = formatter.string(from: Date.now)

        // Sort modules: implemented first, then by name
        let sorted = modules.values.sorted { a, b in
            if a.sourceLineCount != b.sourceLineCount {
                return a.sourceLineCount > b.sourceLineCount
            }
            return a.name < b.name
        }

        // Filter to real modules (not test targets or plugins)
        let realModules = sorted.filter { module in
            module.existsInPackageSwift
                && !module.name.hasSuffix("Tests")
                && !module.name.hasSuffix("Plugin")
        }

        var output = """
        # \(packageName) Master Plan

        **Purpose:** Source of truth for project vision, architecture, and goals.

        <!-- TODO: Add project mission and description -->

        ---

        ## Current Status

        ### What's Working

        """

        for module in realModules {
            let isImplemented = module.sourceLineCount >= configuration.status.stubThresholdLines
            let checkbox = isImplemented ? "[x]" : "[ ]"
            let testInfo = module.estimatedTestCount > 0
                ? " (\(module.estimatedTestCount) tests)"
                : ""
            let description = isImplemented
                ? "\(module.sourceFileCount) source files, \(module.sourceLineCount) lines\(testInfo)"
                : "Not yet implemented"

            output += "- \(checkbox) \(module.name) — \(description)\n"
        }

        let totalTests = realModules.reduce(0) { $0 + $1.estimatedTestCount }
        output += "\n**Total: \(totalTests) estimated tests**\n"

        output += """

        ### Known Issues
        - None currently

        ### Current Priorities
        <!-- TODO: Add current priorities -->
        1. Review and customize this generated Master Plan

        ---

        ## Roadmap

        ### Phase 1: Current (CURRENT)

        """

        for module in realModules {
            let isImplemented = module.sourceLineCount >= configuration.status.stubThresholdLines
            let checkbox = isImplemented ? "[x]" : "[ ]"
            output += "- \(checkbox) \(module.name)\n"
        }

        output += """

        <!-- TODO: Organize into meaningful phases -->

        ---

        **Last Updated:** \(today)

        """

        return output
    }

    // MARK: - Private Helpers

    private static func parsePackageName(at path: String) -> String {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "Project"
        }

        let pattern = #"name:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: content,
                range: NSRange(content.startIndex..., in: content)
              ),
              let nameRange = Range(match.range(at: 1), in: content) else {
            return "Project"
        }

        return String(content[nameRange])
    }
}
