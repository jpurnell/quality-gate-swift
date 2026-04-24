import Foundation
import QualityGateCore

/// Result of a trial build to verify whether the project can be upgraded.
public enum VerificationResult: Sendable, Equatable {
    /// The project builds successfully at the target version.
    case upgradeable
    /// The project fails to build at the target version.
    case blocked(errors: [Diagnostic])
}

/// Checks that the project's `swift-tools-version` meets a configurable minimum
/// and verifies the upgrade is feasible via a trial build.
///
/// ## Check Behavior
///
/// 1. Reads `Package.swift` and parses the `swift-tools-version` comment.
/// 2. Compares against the configured minimum (default: `"6.2"`).
/// 3. If below minimum, performs a trial build with a rewritten `Package.swift`
///    to verify whether the upgrade is feasible.
/// 4. Optionally reports the local compiler version for context.
///
/// ## Fix Behavior
///
/// When `--fix` is passed:
/// 1. Rewrites the `swift-tools-version` line to the configured minimum.
/// 2. Runs `swift build` to verify the project compiles.
/// 3. If the build fails, reverts to the backup and reports errors as unfixed.
///
/// ## Configuration
///
/// ```yaml
/// swiftVersion:
///   minimum: "6.2"
///   checkCompiler: true
/// ```
public struct SwiftVersionChecker: QualityChecker, FixableChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "swift-version"

    /// Human-readable name for this checker.
    public let name = "Swift Version Checker"

    /// Description of what fix mode does.
    public let fixDescription = "Updates swift-tools-version in Package.swift to the configured minimum after verifying the project builds at that version."

    /// Creates a new SwiftVersionChecker instance.
    public init() {}

    // MARK: - QualityChecker

    /// Run the version check with verification build when below minimum.
    ///
    /// - Parameter configuration: Project-specific configuration.
    /// - Returns: Check result with version diagnostics and verification status.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let projectRoot = FileManager.default.currentDirectoryPath
        let packagePath = (projectRoot as NSString).appendingPathComponent("Package.swift")

        // Parse tools-version from Package.swift
        let toolsVersion: String?
        if FileManager.default.fileExists(atPath: packagePath) {
            let content = try String(contentsOfFile: packagePath, encoding: .utf8)
            toolsVersion = Self.parseToolsVersion(from: content)
        } else {
            toolsVersion = nil
        }

        // Get compiler version if configured
        let compilerVersion: String?
        if configuration.swiftVersion.checkCompiler {
            compilerVersion = try await getCompilerVersion()
        } else {
            compilerVersion = nil
        }

        // Run verification build if below minimum
        let minimumVersion = configuration.swiftVersion.minimum
        var verificationResult: VerificationResult?

        if let toolsVersion,
           Self.compareVersions(toolsVersion, minimumVersion) == .orderedAscending {
            verificationResult = try await runVerificationBuild(
                packagePath: packagePath,
                targetVersion: minimumVersion
            )
        }

        let duration = ContinuousClock.now - startTime
        return Self.createCheckResult(
            toolsVersion: toolsVersion,
            minimumVersion: minimumVersion,
            compilerVersion: compilerVersion ?? "unknown",
            checkCompiler: configuration.swiftVersion.checkCompiler,
            verificationResult: verificationResult,
            duration: duration
        )
    }

    // MARK: - FixableChecker

    /// Apply the version upgrade after verifying it builds.
    ///
    /// - Parameters:
    ///   - diagnostics: Diagnostics from a prior `check()` call.
    ///   - configuration: Project-specific configuration.
    /// - Returns: Fix result describing what was changed.
    public func fix(
        diagnostics: [Diagnostic],
        configuration: Configuration
    ) async throws -> FixResult {
        let projectRoot = FileManager.default.currentDirectoryPath
        let packagePath = (projectRoot as NSString).appendingPathComponent("Package.swift")

        guard FileManager.default.fileExists(atPath: packagePath) else {
            return FixResult(modifications: [], unfixed: diagnostics)
        }

        let content = try String(contentsOfFile: packagePath, encoding: .utf8)
        let targetVersion = configuration.swiftVersion.minimum

        guard let rewritten = Self.rewriteToolsVersion(in: content, to: targetVersion) else {
            return FixResult(modifications: [], unfixed: diagnostics)
        }

        // Create backup
        let backupPath = packagePath + ".backup-\(ISO8601DateFormatter().string(from: Date()))"
        try content.write(toFile: backupPath, atomically: true, encoding: .utf8)

        // Write the updated Package.swift
        try rewritten.write(toFile: packagePath, atomically: true, encoding: .utf8)

        // Verify build
        let (_, exitCode) = try await runSwiftBuild()

        if exitCode == 0 {
            // Build succeeded — keep the change
            return FixResult(
                modifications: [
                    FileModification(
                        filePath: packagePath,
                        description: "Updated swift-tools-version to \(targetVersion)",
                        linesChanged: 1,
                        backupPath: backupPath
                    )
                ],
                unfixed: []
            )
        } else {
            // Build failed — revert
            try content.write(toFile: packagePath, atomically: true, encoding: .utf8)
            // Clean up backup since we reverted
            try? FileManager.default.removeItem(atPath: backupPath) // SAFETY: CLI removes its own backup

            return FixResult(
                modifications: [],
                unfixed: diagnostics + [
                    Diagnostic(
                        severity: .error,
                        message: "Cannot upgrade to \(targetVersion): build failed. Manual intervention required.",
                        file: packagePath,
                        ruleId: "swift-version-upgrade-blocked"
                    )
                ]
            )
        }
    }

    // MARK: - Public API for Testing

    /// Parse the `swift-tools-version` from Package.swift content.
    ///
    /// Handles formats: `// swift-tools-version: 6.0`, `// swift-tools-version:5.9`,
    /// and versions with or without patch components.
    ///
    /// - Parameter content: The raw content of Package.swift.
    /// - Returns: The version string, or nil if not found.
    public static func parseToolsVersion(from content: String) -> String? {
        let pattern = #"//\s*swift-tools-version:\s*(\d+(?:\.\d+)*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let versionRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return String(content[versionRange])
    }

    /// Parse the Swift compiler version from `swift --version` output.
    ///
    /// Handles both Apple Swift (`Apple Swift version X.Y.Z`) and
    /// open-source Swift (`Swift version X.Y.Z`) formats.
    ///
    /// - Parameter output: The raw output from `swift --version`.
    /// - Returns: The version string, or nil if not parseable.
    public static func parseCompilerVersion(from output: String) -> String? {
        let pattern = #"(?:Apple )?Swift version (\d+\.\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let versionRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[versionRange])
    }

    /// Compare two semantic version strings.
    ///
    /// Supports versions with 1, 2, or 3 components. Missing components
    /// are treated as zero (e.g., `"6.0"` equals `"6.0.0"`).
    ///
    /// - Parameters:
    ///   - lhs: The left-hand version string.
    ///   - rhs: The right-hand version string.
    /// - Returns: The comparison result.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }

        let maxCount = max(lhsParts.count, rhsParts.count)
        for i in 0..<maxCount {
            let l = i < lhsParts.count ? lhsParts[i] : 0
            let r = i < rhsParts.count ? rhsParts[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    /// Create a check result from parsed version data.
    ///
    /// - Parameters:
    ///   - toolsVersion: The parsed swift-tools-version, or nil if Package.swift missing.
    ///   - minimumVersion: The configured minimum version.
    ///   - compilerVersion: The local compiler version string.
    ///   - checkCompiler: Whether compiler checks are enabled.
    ///   - verificationResult: Result of trial build, if performed.
    ///   - duration: How long the check took.
    /// - Returns: A CheckResult with appropriate status and diagnostics.
    public static func createCheckResult(
        toolsVersion: String?,
        minimumVersion: String,
        compilerVersion: String,
        checkCompiler: Bool,
        verificationResult: VerificationResult?,
        duration: Duration = .zero
    ) -> CheckResult {
        var diagnostics: [Diagnostic] = []

        // No Package.swift found
        guard let toolsVersion else {
            return CheckResult(
                checkerId: "swift-version",
                status: .skipped,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No Package.swift found; skipping version check.",
                        ruleId: "swift-version-skip"
                    )
                ],
                duration: duration
            )
        }

        let comparison = compareVersions(toolsVersion, minimumVersion)
        let isBelowMinimum = comparison == .orderedAscending

        if isBelowMinimum {
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "swift-tools-version \(toolsVersion) is below minimum \(minimumVersion).",
                file: "Package.swift",
                line: 1,
                ruleId: "swift-version-minimum",
                suggestedFix: "Update swift-tools-version to \(minimumVersion)"
            ))
        }

        // Compiler mismatch warning
        if checkCompiler && compilerVersion != "unknown" {
            let compilerComparison = compareVersions(toolsVersion, compilerVersion)
            if compilerComparison == .orderedDescending {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "swift-tools-version \(toolsVersion) exceeds installed compiler version \(compilerVersion). Build may fail.",
                    ruleId: "swift-version-compiler-mismatch"
                ))
            }
        }

        // Verification results
        if let verificationResult {
            switch verificationResult {
            case .upgradeable:
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: "Upgrade verified: project builds successfully at swift-tools-version \(minimumVersion).",
                    ruleId: "swift-version-verified"
                ))
            case .blocked(let errors):
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: "Upgrade blocked: project does not build at swift-tools-version \(minimumVersion).",
                    ruleId: "swift-version-blocked"
                ))
                diagnostics.append(contentsOf: errors)
            }
        }

        let status: CheckResult.Status = isBelowMinimum ? .failed : .passed
        return CheckResult(
            checkerId: "swift-version",
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    /// Rewrite the `swift-tools-version` line in Package.swift content.
    ///
    /// - Parameters:
    ///   - content: The original Package.swift content.
    ///   - version: The new version to set.
    /// - Returns: The rewritten content, or nil if no tools-version line found.
    public static func rewriteToolsVersion(in content: String, to version: String) -> String? {
        let pattern = #"//\s*swift-tools-version:\s*\d+(?:\.\d+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(content.startIndex..., in: content)
        guard regex.firstMatch(in: content, range: range) != nil else {
            return nil
        }
        return regex.stringByReplacingMatches(
            in: content,
            range: range,
            withTemplate: "// swift-tools-version: \(version)"
        )
    }

    // MARK: - Private Implementation

    /// Get the local Swift compiler version.
    private func getCompilerVersion() async throws -> String? {
        let (output, _) = try await runProcess(
            executable: "/usr/bin/swift",
            arguments: ["--version"]
        )
        return Self.parseCompilerVersion(from: output)
    }

    /// Run a verification build with a temporarily rewritten Package.swift.
    private func runVerificationBuild(
        packagePath: String,
        targetVersion: String
    ) async throws -> VerificationResult {
        let original = try String(contentsOfFile: packagePath, encoding: .utf8)

        guard let rewritten = Self.rewriteToolsVersion(in: original, to: targetVersion) else {
            return .blocked(errors: [
                Diagnostic(
                    severity: .error,
                    message: "Could not rewrite swift-tools-version for verification.",
                    ruleId: "swift-version-rewrite-error"
                )
            ])
        }

        // Write temp version
        try rewritten.write(toFile: packagePath, atomically: true, encoding: .utf8)

        defer {
            // Always restore original
            try? original.write(toFile: packagePath, atomically: true, encoding: .utf8)
        }

        let (output, exitCode) = try await runSwiftBuild()

        if exitCode == 0 {
            return .upgradeable
        } else {
            let errors = parseBuildErrors(from: output)
            return .blocked(errors: errors)
        }
    }

    /// Run `swift build` and return the combined output and exit code.
    private func runSwiftBuild() async throws -> (output: String, exitCode: Int32) {
        return try await runProcess(
            executable: "/usr/bin/swift",
            arguments: ["build"]
        )
    }

    /// Run a process and capture combined stdout/stderr.
    private func runProcess(
        executable: String,
        arguments: [String]
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process() // SAFETY: CLI tool runs swift commands
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        return (output + "\n" + errorOutput, process.terminationStatus)
    }

    /// Parse build error diagnostics from Swift compiler output.
    private func parseBuildErrors(from output: String) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let pattern = #"^(.+?):(\d+):(\d+): error: (.+)$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            return []
        }

        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: range)

        for match in matches {
            guard match.numberOfRanges == 5,
                  let fileRange = Range(match.range(at: 1), in: output),
                  let lineRange = Range(match.range(at: 2), in: output),
                  let messageRange = Range(match.range(at: 4), in: output) else {
                continue
            }

            diagnostics.append(Diagnostic(
                severity: .error,
                message: String(output[messageRange]),
                file: String(output[fileRange]),
                line: Int(output[lineRange]),
                ruleId: "swift-compiler"
            ))
        }

        return diagnostics
    }
}
