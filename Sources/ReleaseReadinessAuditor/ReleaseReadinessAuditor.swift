import Foundation
import QualityGateCore

/// Checks release readiness by scanning for changelog entries, README markers, and source TODOs.
///
/// Detected rules:
/// - `release-changelog`: No CHANGELOG.md found, or no entry matching the current version.
/// - `release-todo-readme`: README.md contains TODO, FIXME, HACK, XXX, PLACEHOLDER, or custom markers.
/// - `release-todo-sources`: Source files contain TODO/FIXME without issue references (when configured).
///
/// This auditor is file-based and does not require SwiftSyntax.
public struct ReleaseReadinessAuditor: QualityChecker, Sendable {

    /// Unique identifier used to tag diagnostics from this checker.
    public let id = "release-readiness"

    /// Human-readable display name for reports.
    public let name = "Release Readiness Auditor"

    /// Creates a new release readiness auditor.
    public init() {}

    /// Runs all release readiness rules.
    ///
    /// - Parameter configuration: Gate-wide configuration including release readiness settings.
    /// - Returns: The check result with status and diagnostics.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let config = configuration.releaseReadiness
        let fileManager = FileManager.default
        let projectRoot = fileManager.currentDirectoryPath

        var diagnostics: [Diagnostic] = []

        // 1. Detect version from git tags
        let version = detectVersion(projectRoot: projectRoot)

        // 2. Check CHANGELOG
        let changelogFullPath = (projectRoot as NSString).appendingPathComponent(config.changelogPath)
        if fileManager.fileExists(atPath: changelogFullPath) {
            do {
                let content = try String(contentsOfFile: changelogFullPath, encoding: .utf8)
                diagnostics.append(
                    contentsOf: Self.checkChangelog(content: content, version: version)
                )
            } catch {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Could not read CHANGELOG at \(config.changelogPath): \(error.localizedDescription)",
                    filePath: changelogFullPath,
                    ruleId: "release-changelog"
                ))
            }
        } else {
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "No CHANGELOG found at \(config.changelogPath)",
                filePath: changelogFullPath,
                ruleId: "release-changelog"
            ))
        }

        // 3. Check README for markers
        let allMarkers = Self.defaultMarkers + config.additionalMarkers
        let readmeFullPath = (projectRoot as NSString).appendingPathComponent(config.readmePath)
        if fileManager.fileExists(atPath: readmeFullPath) {
            do {
                let content = try String(contentsOfFile: readmeFullPath, encoding: .utf8)
                diagnostics.append(
                    contentsOf: Self.checkReadme(
                        content: content,
                        markers: allMarkers,
                        filePath: readmeFullPath
                    )
                )
            } catch {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Could not read README at \(config.readmePath): \(error.localizedDescription)",
                    filePath: readmeFullPath,
                    ruleId: "release-todo-readme"
                ))
            }
        } else {
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "No README found at \(config.readmePath)",
                filePath: readmeFullPath,
                ruleId: "release-todo-readme"
            ))
        }

        // 4. Check source TODOs (only when requireIssueReference is true)
        if config.requireIssueReference {
            let sourcesPath = (projectRoot as NSString).appendingPathComponent("Sources")
            if fileManager.fileExists(atPath: sourcesPath) {
                let sourceDiags = scanSourceDirectory(
                    at: sourcesPath,
                    requireIssueReference: config.requireIssueReference,
                    excludePatterns: configuration.excludePatterns
                )
                diagnostics.append(contentsOf: sourceDiags)
            }
        }

        let duration = ContinuousClock.now - startTime

        let hasError = diagnostics.contains { $0.severity == .error }
        let hasWarning = diagnostics.contains { $0.severity == .warning }
        let status: CheckResult.Status
        if hasError {
            status = .failed
        } else if hasWarning {
            status = .warning
        } else {
            status = .passed
        }

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    // MARK: - Default Markers

    /// The default set of markers scanned in README files.
    static let defaultMarkers = ["TODO", "FIXME", "HACK", "XXX", "PLACEHOLDER"]

    // MARK: - Changelog Checking

    /// Checks changelog content for a matching version entry.
    ///
    /// - Parameters:
    ///   - content: The full text of the CHANGELOG file.
    ///   - version: The version string to look for, or nil if version could not be detected.
    /// - Returns: An array of diagnostics. Empty if the version is found or version is nil.
    static func checkChangelog(content: String, version: String?) -> [Diagnostic] {
        guard let version else {
            // Cannot verify without a version; skip silently
            return []
        }

        let lines = content.components(separatedBy: "\n")
        let versionFound = lines.contains { line in
            line.contains(version)
        }

        guard versionFound else {
            return [
                Diagnostic(
                    severity: .warning,
                    message: "CHANGELOG has no entry for version \(version)",
                    ruleId: "release-changelog"
                )
            ]
        }

        return []
    }

    // MARK: - README Checking

    /// Checks README content for marker patterns like TODO, FIXME, etc.
    ///
    /// - Parameters:
    ///   - content: The full text of the README file.
    ///   - markers: The list of marker strings to search for (case-insensitive).
    ///   - filePath: The file path for diagnostic reporting.
    /// - Returns: An array of diagnostics, one per line containing a marker.
    static func checkReadme(
        content: String,
        markers: [String],
        filePath: String
    ) -> [Diagnostic] {
        guard !markers.isEmpty else { return [] }

        let lines = content.components(separatedBy: "\n")
        var diagnostics: [Diagnostic] = []
        let lowercasedMarkers = markers.map { $0.lowercased() }

        for (index, line) in lines.enumerated() {
            let lowercasedLine = line.lowercased()
            for marker in lowercasedMarkers {
                if lowercasedLine.contains(marker) {
                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "README contains '\(marker.uppercased())' marker",
                        filePath: filePath,
                        lineNumber: index + 1,
                        ruleId: "release-todo-readme"
                    ))
                    break // One diagnostic per line, even if multiple markers match
                }
            }
        }

        return diagnostics
    }

    // MARK: - Source TODO Checking

    /// Checks source file content for TODO/FIXME comments without issue references.
    ///
    /// When `requireIssueReference` is true, flags bare `TODO` and `FIXME` markers
    /// that lack a parenthesized reference such as `TODO(#123)` or `FIXME(JIRA-456)`.
    ///
    /// - Parameters:
    ///   - content: The full text of a Swift source file.
    ///   - filePath: The file path for diagnostic reporting.
    ///   - requireIssueReference: Whether to require issue references on TODOs.
    /// - Returns: An array of diagnostics for bare TODO/FIXME comments.
    static func checkSourceTodos(
        content: String,
        filePath: String,
        requireIssueReference: Bool
    ) -> [Diagnostic] {
        guard requireIssueReference else { return [] }

        let lines = content.components(separatedBy: "\n")
        var diagnostics: [Diagnostic] = []

        // Pattern: TODO or FIXME followed immediately by ( means it has a reference
        // We flag lines with TODO/FIXME that do NOT have a parenthesized reference
        let todoPattern = #/(?i)\b(TODO|FIXME)\b/#
        let refPattern = #/(?i)\b(TODO|FIXME)\s*\(/#

        for (index, line) in lines.enumerated() {
            guard line.contains(todoPattern) else { continue }

            // If the line has TODO(...) or FIXME(...), it has a reference
            if line.contains(refPattern) {
                continue
            }

            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "TODO/FIXME without issue reference",
                filePath: filePath,
                lineNumber: index + 1,
                ruleId: "release-todo-sources"
            ))
        }

        return diagnostics
    }

    // MARK: - Private Helpers

    /// Attempts to detect the current project version from git tags.
    ///
    /// Falls back to scanning source files for `version:` patterns if git is unavailable.
    ///
    /// - Parameter projectRoot: The project root directory path.
    /// - Returns: A version string, or nil if detection fails.
    private func detectVersion(projectRoot: String) -> String? {
        // Try git describe first
        if let gitVersion = runGitDescribe(in: projectRoot) {
            return gitVersion
        }

        // Fallback: scan for version in source files
        return scanForVersionInSources(projectRoot: projectRoot)
    }

    /// Runs `git describe --tags --abbrev=0` to get the latest tag.
    ///
    /// - Parameter directory: The directory to run git in.
    /// - Returns: The tag string (trimmed), or nil on failure.
    private func runGitDescribe(in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["describe", "--tags", "--abbrev=0"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Suppress stderr

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip leading 'v' if present (e.g., v1.2.0 -> 1.2.0)
            if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
                return String(trimmed.dropFirst())
            }
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    /// Scans source files for a `version:` or `version =` pattern.
    ///
    /// - Parameter projectRoot: The project root directory path.
    /// - Returns: A version string if found, or nil.
    private func scanForVersionInSources(projectRoot: String) -> String? {
        let fileManager = FileManager.default
        let sourcesPath = (projectRoot as NSString).appendingPathComponent("Sources")
        guard let enumerator = fileManager.enumerator(atPath: sourcesPath) else {
            return nil
        }

        let versionPattern = #/version\s*[:=]\s*"?(\d+\.\d+(?:\.\d+)?)"?/#

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let fullPath = (sourcesPath as NSString).appendingPathComponent(relativePath)
            do {
                let content = try String(contentsOfFile: fullPath, encoding: .utf8)
                if let match = content.firstMatch(of: versionPattern) {
                    return String(match.1)
                }
            } catch {
                continue
            }
        }

        return nil
    }

    /// Recursively scans the Sources directory for Swift files with bare TODOs.
    ///
    /// - Parameters:
    ///   - path: The absolute path to the Sources directory.
    ///   - requireIssueReference: Whether to require issue references.
    ///   - excludePatterns: Glob patterns to exclude.
    /// - Returns: An array of diagnostics from all scanned files.
    private func scanSourceDirectory(
        at path: String,
        requireIssueReference: Bool,
        excludePatterns: [String]
    ) -> [Diagnostic] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: path) else { return [] }

        var diagnostics: [Diagnostic] = []

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            // Skip excluded patterns
            let excluded = excludePatterns.contains { pattern in
                relativePath.contains(
                    pattern.replacingOccurrences(of: "**/", with: "")
                        .replacingOccurrences(of: "/**", with: "")
                )
            }
            if excluded { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            do {
                let content = try String(contentsOfFile: fullPath, encoding: .utf8)
                diagnostics.append(
                    contentsOf: Self.checkSourceTodos(
                        content: content,
                        filePath: fullPath,
                        requireIssueReference: requireIssueReference
                    )
                )
            } catch {
                continue
            }
        }

        return diagnostics
    }
}
