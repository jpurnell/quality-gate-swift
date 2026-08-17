import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
import QualityGateCore

/// Executes `swift build` and reports results.
///
/// BuildChecker runs the Swift compiler and parses its output into structured
/// diagnostics. It detects errors, warnings, and notes from the build process.
///
/// ## Usage
///
/// ```swift
/// import QualityGateCore
///
/// let config = Configuration()
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

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "`swift build` wrapper — captures all compiler errors and warnings"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.projectHealth

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Spawns `swift build`, which locks the SwiftPM `.build` directory — must run
    /// sequentially, outside the concurrent task group.
    public var isParallelSafe: Bool { false }

    /// Creates a new BuildChecker instance.
    public init() {}

    /// Declares this checker cacheable on the whole source tree.
    ///
    /// "Does this package compile" is a function of the sources and the manifests, both in the
    /// fingerprint, and of the toolchain, which `gateIdentityHash` salts in.
    ///
    /// A cache hit means the compiler did not run. That is sound for *this* checker's verdict —
    /// the same sources under the same toolchain still compile — but it is worth stating,
    /// because a hit does not repopulate `.build`. Anything that needs artifacts rather than a
    /// verdict must not infer their existence from this checker passing.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSource(
            projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            configuration: configuration
        )
    }

    /// Run the build check.
    ///
    /// Executes `swift build` and parses any compiler diagnostics.
    /// Skips automatically when no Package.swift is present (Xcode-only projects).
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let projectRoot = FileManager.default.currentDirectoryPath
        let packagePath = (projectRoot as NSString).appendingPathComponent("Package.swift")

        guard FileManager.default.fileExists(atPath: packagePath) else {
            let duration = ContinuousClock.now - startTime
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No Package.swift found; skipping SPM build.",
                        ruleId: "build-skip"
                    )
                ],
                duration: duration
            )
        }

        let args = buildArguments(for: configuration)
        let (output, exitCode) = try await runSwiftBuild(arguments: args)

        let duration = ContinuousClock.now - startTime
        return Self.createResult(output: output, exitCode: exitCode, duration: duration)
    }

    // MARK: - Public API for Testing

    /// Strips ANSI SGR escape sequences (`ESC[…m`) from compiler output.
    ///
    /// `swift build` colourises diagnostics even when its output is a pipe rather than
    /// a terminal, so a real warning arrives as
    /// `File.swift:140:17: ESC[1;33mwarning: ESC[1;39mmessage ESC[0;0m`. Left in, the
    /// escapes sit between the colon and the severity word, where the diagnostic
    /// pattern expects nothing — and they would also travel into any report built from
    /// the message.
    ///
    /// - Parameter text: Raw compiler output, possibly colourised.
    /// - Returns: The same text with SGR escape sequences removed.
    private static func strippingANSIEscapes(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
    }

    /// The last `lines` lines of `text`, for reporting a failure no pattern matched.
    ///
    /// Bounded because build output can be enormous and a diagnostic is read by a human; the
    /// tail is where the failure is.
    static func tail(of text: String, lines: Int) -> String {
        // `.lines`, not `split(separator: "\n")` — CRLF is one Swift `Character`, so splitting on
        // a newline literal returns a CRLF document as a single element and the "tail" becomes
        // the whole build log. Caught by the gate's own newline-split rule on this very helper.
        let all = text.lines
        guard all.count > lines else { return text }
        return all.suffix(lines).joined(separator: "\n")
    }

    /// Parse Swift compiler output into diagnostics.
    ///
    /// This method is exposed for testing purposes. It extracts file locations,
    /// severity levels, and messages from compiler output, after removing any ANSI
    /// colour escapes the compiler emitted around the severity token.
    ///
    /// - Parameter rawOutput: The raw output from `swift build`, as emitted.
    /// - Returns: An array of diagnostics parsed from the output
    public static func parseBuildOutput(_ rawOutput: String) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        let output = strippingANSIEscapes(rawOutput)

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
                // A failure must always say something.
                //
                // `parseBuildOutput` matches `File.swift:line:col: severity: message`, which is
                // the shape of a *compiler* diagnostic. A build can fail in other shapes —
                // linker errors (`error: Ld … failed with a nonzero exit code`), code-signing,
                // a manifest that will not evaluate — and those parse to nothing. The result was
                // then `.failed` with an empty diagnostics array, so the gate printed
                // `✗ [build] FAILED (72.32s)` and not one word about why.
                //
                // Observed 2026-08-17: a test target missing a dependency took the gate red, and
                // the cause was only found by running `swift build --build-tests` by hand. The
                // checker that exists to surface compiler output had surfaced none of it.
                if diagnostics.isEmpty {
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "swift build failed (exit \(exitCode)) with no parseable "
                            + "compiler diagnostic — the failure is below, verbatim:\n"
                            + Self.tail(of: output, lines: 20),
                        ruleId: "build-unparsed-failure"
                    ))
                }
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

        // Plain `swift build` compiles only the library, so every diagnostic in the
        // test target goes unread — while the test checker compiles those same files
        // moments later and keeps only the test results. A package can report zero
        // warnings with a test target full of them.
        if configuration.build.includeTests {
            args.append("--build-tests")
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
