import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// Checks release readiness by scanning for changelog entries, README markers, and source TODOs.
///
/// Detected rules:
/// - `release-changelog`: No CHANGELOG.md found, or no entry matching the current version.
/// - `release-todo-readme`: README.md contains TODO, FIXME, HACK, XXX, PLACEHOLDER, or custom markers.
/// - `release-todo-sources`: Source files contain TODO/FIXME without issue references (when configured).
/// - `release-untagged-version` (error): The latest CHANGELOG version has no matching git tag,
///   so consumers cannot resolve the release. Enforces the corrected invariant — the *documented*
///   version must be tagged, not merely that the current tag is documented.
/// - `release-unresolvable-dependency` (error): A README-advertised `from:`/`.exact` dependency
///   version has no matching git tag.
///
/// This auditor is file-based and does not require SwiftSyntax.
public struct ReleaseReadinessAuditor: QualityChecker, Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "ReleaseReadinessAuditor")

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

        // 1b. Gather git tags once for parity checks (empty when not a git repo).
        let tags = gitTags(in: projectRoot)

        // 2. Check CHANGELOG
        let changelogFullPath = (projectRoot as NSString).appendingPathComponent(config.changelogPath)
        // SECURITY: CLI tool reads local project file — path derived from validated project root
        if fileManager.fileExists(atPath: changelogFullPath) {
            do {
                let content = try String(contentsOfFile: changelogFullPath, encoding: .utf8)
                diagnostics.append(
                    contentsOf: Self.checkChangelog(content: content, version: version)
                )
                // Corrected invariant: the documented latest version MUST be tagged.
                if config.checkVersionTagParity {
                    let latest = Self.parseLatestChangelogVersion(content: content)
                    diagnostics.append(
                        contentsOf: Self.checkVersionTagParity(latestChangelogVersion: latest, tags: tags)
                    )
                }
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
        // SECURITY: CLI tool reads local project file — path derived from validated project root
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
                // Every dependency version the README advertises must resolve to a tag.
                if config.checkDependencyResolvability {
                    let advertised = Self.parseReadmeDependencyVersions(content: content)
                    diagnostics.append(
                        contentsOf: Self.checkDependencyVersionsResolvable(
                            readmeVersions: advertised,
                            tags: tags,
                            filePath: readmeFullPath
                        )
                    )
                }
            } catch {
                Self.logger.warning("Could not read README at \(config.readmePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            // SECURITY: CLI tool reads local project Sources directory
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

        let lines = content.lines
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

        let lines = content.lines
        var diagnostics: [Diagnostic] = []
        let markerPatterns: [(String, Regex<AnyRegexOutput>)] = markers.compactMap { marker in
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            do {
                let pattern = try Regex("(?i)\\b\(escaped)\\b")
                return (marker.uppercased(), pattern)
            } catch {
                logger.warning("Failed to compile regex for marker '\(marker, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        for (index, line) in lines.enumerated() {
            for (markerName, pattern) in markerPatterns {
                if line.contains(pattern) {
                    diagnostics.append(Diagnostic(
                        severity: .warning,
                        message: "README contains '\(markerName)' marker",
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

        let lines = content.lines
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

    // MARK: - Version / Tag Parity

    /// Normalizes a version string by trimming whitespace, stripping a monorepo
    /// `Project@` tag prefix, and stripping a leading `v`/`V`.
    ///
    /// Handles the monorepo tag convention (`IconquerApp@v0.1.0`) alongside plain
    /// (`v1.2.0`) and bare (`1.0.0`) forms so all three normalize to the same bare
    /// semver — the CHANGELOG parser already extracts a bare semver, so the tag
    /// side must reduce to one too for parity to match.
    ///
    /// - Parameter raw: A version or tag string such as `"IconquerApp@v0.1.0"`,
    ///   `"v1.2.0"`, or `" 1.0.0 "`.
    /// - Returns: The bare semver string, e.g. `"1.2.0"`.
    static func normalizeVersion(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a monorepo scope prefix like `Project@` (keep only what follows the last `@`).
        if let lastAt = trimmed.lastIndex(of: "@") {
            trimmed = String(trimmed[trimmed.index(after: lastAt)...])
        }
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    /// Extracts the topmost *released* version from a CHANGELOG, skipping an `Unreleased` heading.
    ///
    /// Recognizes headings like `## 2.0.1`, `## [1.4.0] - 2026-06-07`, and `## v3.1.0`.
    ///
    /// - Parameter content: The full text of the CHANGELOG.
    /// - Returns: The latest released version (normalized), or nil if only an
    ///   `Unreleased` section (or no version heading) is present.
    static func parseLatestChangelogVersion(content: String) -> String? {
        let headingPattern = #/^\s*#{1,6}\s+(.*)$/#
        let semverPattern = #/v?(\d+\.\d+(?:\.\d+)?)/#
        for line in content.lines {
            guard let heading = line.firstMatch(of: headingPattern) else { continue }
            let text = String(heading.1)
            if text.lowercased().contains("unreleased") { continue }
            if let semver = text.firstMatch(of: semverPattern) {
                return String(semver.1)
            }
        }
        return nil
    }

    /// Verifies the documented latest version has a matching git tag (the release invariant).
    ///
    /// This is the corrected direction: rather than asking whether the current
    /// tag is documented, it asks whether the *documented* version is tagged —
    /// the failure mode where a CHANGELOG races ahead of the tags and consumers
    /// cannot resolve the package.
    ///
    /// - Parameters:
    ///   - latestChangelogVersion: The latest released version from the CHANGELOG, or nil.
    ///   - tags: The project's git tags (with or without a `v` prefix).
    /// - Returns: A single `.error` diagnostic when the version is untagged, else empty.
    static func checkVersionTagParity(latestChangelogVersion: String?, tags: [String]) -> [Diagnostic] {
        guard let version = latestChangelogVersion else { return [] }
        let normalizedTags = Set(tags.map(normalizeVersion))
        guard normalizedTags.contains(normalizeVersion(version)) else {
            return [
                Diagnostic(
                    severity: .error,
                    message: "CHANGELOG documents version \(version) but no matching git tag exists — consumers cannot resolve this release. Tag it (e.g. `git tag v\(version) && git push --tags`).",
                    ruleId: "release-untagged-version"
                )
            ]
        }
        return []
    }

    /// Extracts dependency versions a README advertises for consumers to resolve against.
    ///
    /// Recognizes `from: "X.Y.Z"` and `.exact("X.Y.Z")` (the latter also covers
    /// `upToNextMajor(from: "X.Y.Z")` via its `from:` clause).
    ///
    /// - Parameter content: The full text of the README.
    /// - Returns: The advertised version strings (normalized, de-duplicated, order-preserving).
    static func parseReadmeDependencyVersions(content: String) -> [String] {
        let fromPattern = #/from:\s*"(\d+\.\d+(?:\.\d+)?)"/#
        let exactPattern = #/\.exact\(\s*"(\d+\.\d+(?:\.\d+)?)"\s*\)/#
        var found: [String] = []
        var seen: Set<String> = []
        func collect(_ version: Substring) {
            let normalized = normalizeVersion(String(version))
            if seen.insert(normalized).inserted {
                found.append(normalized)
            }
        }
        for match in content.matches(of: fromPattern) { collect(match.1) }
        for match in content.matches(of: exactPattern) { collect(match.1) }
        return found
    }

    /// Verifies every README-advertised dependency version resolves to an existing tag.
    ///
    /// - Parameters:
    ///   - readmeVersions: Versions advertised in the README (from `parseReadmeDependencyVersions`).
    ///   - tags: The project's git tags.
    ///   - filePath: Optional path used for diagnostic reporting.
    /// - Returns: One `.error` diagnostic per advertised version with no matching tag.
    static func checkDependencyVersionsResolvable(
        readmeVersions: [String],
        tags: [String],
        filePath: String? = nil
    ) -> [Diagnostic] {
        let normalizedTags = Set(tags.map(normalizeVersion))
        return readmeVersions.compactMap { version in
            guard !normalizedTags.contains(normalizeVersion(version)) else { return nil }
            return Diagnostic(
                severity: .error,
                message: "README advertises dependency version \(version) but no matching git tag exists — consumers following the README cannot resolve the package.",
                filePath: filePath,
                ruleId: "release-unresolvable-dependency"
            )
        }
    }

    /// Lists the project's git tags. Returns an empty array when git is unavailable or not a repo.
    ///
    /// - Parameter directory: The project root directory path.
    /// - Returns: The tag names as reported by `git tag`, or an empty array.
    private func gitTags(in directory: String) -> [String] {
        // SECURITY: subprocess with hardcoded /usr/bin/git executable path
        do {
            let result = try ProcessRunner.run(
                "/usr/bin/git",
                arguments: ["tag"],
                currentDirectory: directory
            )
            guard result.exitCode == 0 else { return [] }
            return result.stdout
                .lines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            Self.logger.warning("git tag failed in \(directory, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
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
        // SECURITY: subprocess with hardcoded /usr/bin/git executable path
        do {
            let result = try ProcessRunner.run(
                "/usr/bin/git",
                arguments: ["describe", "--tags", "--abbrev=0"],
                currentDirectory: directory
            )

            guard result.exitCode == 0 else { return nil }

            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip leading 'v' if present (e.g., v1.2.0 -> 1.2.0)
            if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
                return String(trimmed.dropFirst())
            }
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            Self.logger.warning("git describe failed in \(directory, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

        let versionPattern = #/version\s*[:=]\s*"(\d+\.\d+(?:\.\d+)?)"/#

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let fullPath = (sourcesPath as NSString).appendingPathComponent(relativePath)
            do {
                let content = try String(contentsOfFile: fullPath, encoding: .utf8)
                for line in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                    let trimmed = line.drop(while: { $0.isWhitespace })
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                        continue
                    }
                    let lineStr = String(line)
                    if lineStr.contains(".version") { continue }
                    if let match = lineStr.firstMatch(of: versionPattern) {
                        return String(match.1)
                    }
                }
            } catch {
                Self.logger.warning("Skipping unreadable source file during version scan \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
                Self.logger.warning("Skipping unreadable source file during TODO scan \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        return diagnostics
    }
}
