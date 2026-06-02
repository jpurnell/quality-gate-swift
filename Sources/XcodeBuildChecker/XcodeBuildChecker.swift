import Foundation
import QualityGateCore
import BuildChecker

/// Runs `xcodebuild build` for configured scheme × destination combinations
/// and reports compiler diagnostics.
///
/// This checker catches cross-platform build errors invisible to `swift build`,
/// which only compiles for the macOS host target. Xcode builds for all declared
/// platforms (iOS, watchOS, visionOS), exposing availability and Sendable issues
/// in `#if os()` guarded code.
///
/// Opt-in by default — runs only with `--full` or `--check xcode-build`.
///
/// ## Configuration
///
/// ```yaml
/// xcodeBuild:
///   project: MyApp.xcodeproj
///   scheme: MyApp
///   destinations:
///     - "platform=iOS Simulator,name=iPhone 17 Pro"
/// ```
public struct XcodeBuildChecker: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "xcode-build"

    /// Human-readable name for this checker.
    public let name = "Xcode Build Checker"

    /// Creates a new XcodeBuildChecker instance.
    public init() {}

    /// Run xcodebuild for each configured destination and collect diagnostics.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let config = configuration.xcodeBuild

        let projectArgs = try resolveProjectArguments(config)

        guard let projectArgs else {
            let duration = ContinuousClock.now - startTime
            return CheckResult(
                checkerId: id,
                status: .passed,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No Xcode project or workspace found — skipping",
                        ruleId: "xcode-build-skip"
                    )
                ],
                duration: duration
            )
        }

        let scheme = try config.scheme ?? discoverScheme(projectArgs: projectArgs)

        let destinations = config.destinations.isEmpty
            ? ["generic/platform=macOS"]
            : config.destinations

        var allDiagnostics: [Diagnostic] = []
        var anyBuildFailed = false

        for destination in destinations {
            var args = ["build"]
            args.append(contentsOf: projectArgs)
            args.append(contentsOf: ["-scheme", scheme])
            args.append(contentsOf: ["-destination", destination])
            args.append("-quiet")

            // SAFETY: runs xcodebuild to check compilation
            let result = try ProcessRunner.run(
                "/usr/bin/xcodebuild",
                arguments: args
            )

            let combinedOutput = result.stdout + "\n" + result.stderr
            let diagnostics = BuildChecker.parseBuildOutput(combinedOutput)

            let label = destinationLabel(destination)
            let tagged = diagnostics.map { diag in
                Diagnostic(
                    severity: diag.severity,
                    message: "[\(label)] \(diag.message)",
                    filePath: diag.filePath,
                    lineNumber: diag.lineNumber,
                    columnNumber: diag.columnNumber,
                    ruleId: "xcode-compiler"
                )
            }

            allDiagnostics.append(contentsOf: tagged)

            if result.exitCode != 0 {
                let hasCompilationErrors = diagnostics.contains { $0.severity == .error }
                if hasCompilationErrors {
                    anyBuildFailed = true
                }
            }
        }

        let deduped = dedup(allDiagnostics)
        let duration = ContinuousClock.now - startTime

        return CheckResult(
            checkerId: id,
            status: anyBuildFailed ? .failed : .passed,
            diagnostics: deduped,
            duration: duration
        )
    }

    // MARK: - Private

    private func resolveProjectArguments(
        _ config: XcodeBuildCheckerConfig
    ) throws -> [String]? {
        if let workspace = config.workspace {
            return ["-workspace", workspace]
        }
        if let project = config.project {
            return ["-project", project]
        }

        let cwd = FileManager.default.currentDirectoryPath
        // SAFETY: CLI reads local cwd directory listing for Xcode project auto-discovery
        let contents = try FileManager.default.contentsOfDirectory(atPath: cwd)

        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return ["-workspace", workspace]
        }
        if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return ["-project", project]
        }

        return nil
    }

    private func discoverScheme(projectArgs: [String]) throws -> String {
        var args = ["-list", "-json"]
        args.append(contentsOf: projectArgs)

        // SAFETY: runs xcodebuild -list to discover available schemes
        let result = try ProcessRunner.run(
            "/usr/bin/xcodebuild",
            arguments: args
        )

        guard result.exitCode == 0 else {
            throw QualityGateError.configurationError(
                "xcodebuild -list failed: \(result.stderr)"
            )
        }

        guard let data = result.stdout.data(using: .utf8),
              // silent: malformed JSON from xcodebuild handled by throwing configurationError
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QualityGateError.configurationError(
                "Failed to parse xcodebuild -list output"
            )
        }

        let schemesContainer = (json["project"] as? [String: Any])
            ?? (json["workspace"] as? [String: Any])

        guard let schemes = schemesContainer?["schemes"] as? [String],
              let firstScheme = schemes.first else {
            throw QualityGateError.configurationError(
                "No schemes found in Xcode project"
            )
        }

        return firstScheme
    }

    private func destinationLabel(_ destination: String) -> String {
        if destination.contains("iOS") { return "iOS" }
        if destination.contains("watchOS") { return "watchOS" }
        if destination.contains("visionOS") { return "visionOS" }
        if destination.contains("macOS") { return "macOS" }
        if destination.contains("tvOS") { return "tvOS" }
        return destination
    }

    private func dedup(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        var seen = Set<String>()
        return diagnostics.filter { diag in
            let key = "\(diag.filePath ?? ""):\(diag.lineNumber ?? 0):\(diag.message)"
            return seen.insert(key).inserted
        }
    }
}
