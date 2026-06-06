import Foundation
import os
import QualityGateCore

/// Executes `swift build` and reports results.
///
/// BuildChecker runs the Swift compiler and parses its output into structured
/// diagnostics. It detects errors, warnings, and notes from the build process.
///
/// ## Usage
///
/// ```swift
/// let checker = BuildChecker()
/// let result = try await checker.check(configuration: config)
/// ```
///
/// ## Configuration
///
/// Configure via `.quality-gate.yml`:
///
/// ```yaml
/// buildConfiguration: release  # or debug (default)
/// build:
///   solverExpressionTimeThreshold: 500  # ms per-expression type-check limit
/// ```
public struct BuildChecker: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "BuildChecker")

    /// Unique identifier for this checker.
    public let id = "build"

    /// Human-readable name for this checker.
    public let name = "Build Checker"

    /// Creates a new BuildChecker instance.
    public init() {}

    /// Run the build check.
    ///
    /// Executes `swift build` and parses any compiler diagnostics.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let args = buildArguments(for: configuration)
        let (output, exitCode) = try await runSwiftBuild(arguments: args)

        let duration = ContinuousClock.now - startTime
        return Self.createResult(output: output, exitCode: exitCode, duration: duration)
    }

    // MARK: - Public API for Testing

    /// Parse Swift compiler output into diagnostics.
    ///
    /// This method is exposed for testing purposes. It extracts file locations,
    /// severity levels, and messages from compiler output.
    ///
    /// - Parameter output: The raw output from `swift build`
    /// - Returns: An array of diagnostics parsed from the output
    public static func parseBuildOutput(_ output: String) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        // Pattern: /path/to/File.swift:line:column: severity: message
        // The path can contain spaces, so we match until the line:column:severity pattern
        let pattern = #"^(.+?):(\d+):(\d+): (error|warning|note): (.+)$"#

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        } catch {
            logger.warning("Failed to compile build output regex: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: range)

        for match in matches {
            guard match.numberOfRanges == 6 else { continue }

            let fileRange = Range(match.range(at: 1), in: output)
            let lineRange = Range(match.range(at: 2), in: output)
            let columnRange = Range(match.range(at: 3), in: output)
            let severityRange = Range(match.range(at: 4), in: output)
            let messageRange = Range(match.range(at: 5), in: output)

            guard let fileRange, let lineRange, let columnRange,
                  let severityRange, let messageRange else {
                continue
            }

            let file = String(output[fileRange])
            let line = Int(output[lineRange])
            let column = Int(output[columnRange])
            let severityString = String(output[severityRange])
            let message = String(output[messageRange])

            let severity: Diagnostic.Severity
            switch severityString {
            case "error":
                severity = .error
            case "warning":
                severity = .warning
            case "note":
                severity = .note
            default:
                continue
            }

            diagnostics.append(Diagnostic(
                severity: severity,
                message: message,
                filePath: file,
                lineNumber: line,
                columnNumber: column,
                ruleId: "swift-compiler"
            ))
        }

        return diagnostics
    }

    /// Create a CheckResult from build output.
    ///
    /// - Parameters:
    ///   - output: The raw build output
    ///   - exitCode: The exit code from `swift build`
    ///   - duration: How long the build took
    /// - Returns: A CheckResult summarizing the build
    public static func createResult(
        output: String,
        exitCode: Int32,
        duration: Duration
    ) -> CheckResult {
        var diagnostics = parseBuildOutput(output)

        let status: CheckResult.Status
        if exitCode == 0 {
            status = .passed
        } else {
            let hasCompilationErrors = diagnostics.contains { $0.severity == .error }
            if !hasCompilationErrors && isCodeSigningError(output) {
                status = .passed
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Ad-hoc code signing failed (compilation succeeded)",
                    ruleId: "swift-compiler"
                ))
            } else {
                status = .failed
            }
        }

        return CheckResult(
            checkerId: "build",
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    private static func isCodeSigningError(_ output: String) -> Bool {
        output.contains("Code Signing subsystem") || output.contains("codesign failed")
    }

    /// Generate build arguments based on configuration.
    ///
    /// - Parameter configuration: The project configuration
    /// - Returns: Arguments to pass to `swift build`
    public func buildArguments(for configuration: Configuration) -> [String] {
        var args: [String] = []

        if let buildConfig = configuration.buildConfiguration {
            args.append("-c")
            args.append(buildConfig)
        }

        if let threshold = configuration.build.solverExpressionTimeThreshold {
            args.append(contentsOf: [
                "-Xswiftc", "-Xfrontend",
                "-Xswiftc", "-solver-expression-time-threshold=\(threshold)"
            ])
        }

        return args
    }

    // MARK: - Private Implementation

    private func runSwiftBuild(arguments: [String]) async throws -> (output: String, exitCode: Int32) {
        // SAFETY: runs swift build to check compilation
        let result = try ProcessRunner.run(
            "/usr/bin/swift",
            arguments: ["build"] + arguments
        )

        // Combine stdout and stderr since Swift outputs diagnostics to stderr
        let combinedOutput = result.stdout + "\n" + result.stderr

        return (combinedOutput, result.exitCode)
    }
}
