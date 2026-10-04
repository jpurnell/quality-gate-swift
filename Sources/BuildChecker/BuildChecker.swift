import Foundation
import IndexStoreInfra
import QualityGateLogging
import QualityGateCore

/// Executes `swift build` and reports results.
///
/// BuildChecker runs the Swift compiler and parses its output into structured
/// diagnostics. It detects errors, warnings, and notes from the build process.
///
/// An incremental build prints a diagnostic only for the files it recompiles, so after a
/// successful build the checker also reads what the compiler *recorded* for every first-party
/// compile unit — see ``RecordedDiagnostics``. The same tree gives the same warnings on a cold
/// build directory and a warm one, and when the checker cannot establish that, it reports
/// `build.warnings-unverified` instead of passing.
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

    /// Runs the analysed project's own code — a survey must not include this.
    ///
    /// Correctly `.readOnly`: that property deliberately excludes compilation
    /// output. This is the separate question of whether a stranger's code is
    /// executed, and here it is.
    public let executesProjectCode = true
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
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Run the build check.
    ///
    /// Executes `swift build`, parses any compiler diagnostics it printed, and — when the build
    /// succeeded — merges in the diagnostics the compiler recorded for the compile units the
    /// build left alone. Skips automatically when no Package.swift is present (Xcode-only
    /// projects).
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let projectRoot = configuration.resolvedProjectRoot.path
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
        // Wall-clock, because it is compared with file modification dates: a record written
        // since this moment was written by this build.
        let buildStarted = Date()
        let (output, exitCode) = try await runSwiftBuild(arguments: args, in: projectRoot)

        // Success only. After a failure the transcript has the errors, the verdict is already
        // `.failed`, and not every unit ran — the failing file's record is the previous build's.
        let recorded: RecordedDiagnostics? = exitCode == 0
            ? RecordedDiagnostics.collect(
                projectRoot: projectRoot,
                buildConfiguration: configuration.buildConfiguration,
                buildStarted: buildStarted
            )
            : nil

        let duration = ContinuousClock.now - startTime
        return Self.createResult(output: output, exitCode: exitCode, duration: duration, recorded: recorded)
    }

    // MARK: - Public API for Testing

    /// Strips terminal escape sequences from compiler output: ANSI SGR colour (`ESC[…m`) and
    /// OSC 8 hyperlinks (`ESC]8;…;URI` terminated by `ESC\` or BEL).
    ///
    /// `swift build` colourises diagnostics even when its output is a pipe rather than
    /// a terminal, so a real warning arrives as
    /// `File.swift:140:17: ESC[1;33mwarning: ESC[1;39mmessage ESC[0;0m`. Left in, the
    /// escapes sit between the colon and the severity word, where the diagnostic
    /// pattern expects nothing — and they would also travel into any report built from
    /// the message.
    ///
    /// The compiler also wraps a diagnostic's group in a hyperlink to its documentation:
    /// `[#ESC]8;;https://docs.swift.org/…ESC\NoUsageESC]8;;ESC\]`. Stripping colour alone
    /// left the link's payload behind, so every report printed
    /// `[#]8;;https://docs.swift.org/…\NoUsage]8;;\]`. A message is text: with both removed
    /// it reads `[#NoUsage]`, which is also the form a recorded diagnostic is rendered in —
    /// the two must compare equal for a warning that is both printed and recorded to be
    /// reported once.
    ///
    /// - Parameter text: Raw compiler output, possibly colourised.
    /// - Returns: The same text with SGR and OSC 8 escape sequences removed.
    private static func strippingANSIEscapes(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text
            .replacingOccurrences(
                of: "\u{1B}\\]8;[^\u{1B}\u{07}]*(?:\u{1B}\\\\|\u{07})",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
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
    /// severity levels, and messages from compiler output, after removing the ANSI colour
    /// and hyperlink escapes the compiler emits around the severity and the diagnostic group.
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

    /// Removes repeated diagnostics, keeping the first of each.
    ///
    /// Two diagnostics are the same finding when they agree on path, line, column, severity
    /// and message — at which point no reader could tell them apart either. It exists for one
    /// diagnostic reported by two jobs: emit-module and the compile job both report a warning
    /// in a declaration, so two warnings were counted as four; and a file this run compiled is
    /// in both the transcript and its record.
    ///
    /// - Parameter diagnostics: Diagnostics in reporting order.
    /// - Returns: The same diagnostics with later repeats removed, order preserved.
    static func uniqued(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        var seen = Set<String>()
        return diagnostics.filter { diagnostic in
            let key = [
                diagnostic.filePath ?? "",
                diagnostic.lineNumber.map(String.init) ?? "",
                diagnostic.columnNumber.map(String.init) ?? "",
                diagnostic.severity.rawValue,
                diagnostic.message,
            ].joined(separator: "\u{0}")
            return seen.insert(key).inserted
        }
    }

    /// Create a CheckResult from build output and the compiler's recorded diagnostics.
    ///
    /// A successful build's findings are the union of what the build printed and what the
    /// compiler recorded for every first-party compile unit, each reported once: transcript
    /// order first, then recorded. When `recorded` says some unit could not be vouched for,
    /// the result carries `build.warnings-unverified` and is at best a warning; it always
    /// carries the `build.diagnostic-coverage` note. A failed build ignores `recorded`.
    ///
    /// - Parameters:
    ///   - output: The raw build output
    ///   - exitCode: The exit code from `swift build`
    ///   - duration: How long the build took
    ///   - recorded: The recorded diagnostics read after a successful build, or `nil` to judge
    ///     the transcript alone.
    /// - Returns: A CheckResult summarizing the build
    public static func createResult(
        output: String,
        exitCode: Int32,
        duration: Duration,
        recorded: RecordedDiagnostics? = nil
    ) -> CheckResult {
        let succeeded = exitCode == 0
        var diagnostics = uniqued(parseBuildOutput(output) + (succeeded ? recorded?.diagnostics ?? [] : []))
        // The checker's own statements about what it read. Kept apart from compiler
        // diagnostics until after first-party scoping, which is about where a compiler
        // diagnostic points and has nothing to say about these.
        var coverage: [Diagnostic] = []

        let status: CheckResult.Status
        if succeeded {
            if let recorded {
                if let unverified = recorded.unverifiedDiagnostic {
                    coverage.append(unverified)
                }
                coverage.append(recorded.coverageDiagnostic)
            }
            // A compiler warning is a finding, and the verdict says so. As `.passed` it was
            // counted in the summary and nowhere else: the tick stayed green. A pass that
            // cannot be vouched for is not a pass either.
            let warned = (diagnostics + coverage).contains { $0.severity == .warning }
            status = warned ? .warning : .passed
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
            diagnostics: diagnostics.scopedToFirstParty() + coverage,
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

    private func runSwiftBuild(arguments: [String], in root: String) async throws -> (output: String, exitCode: Int32) {
        // SAFETY: runs swift build to check compilation
        let result = try ProcessRunner.run(
            "/usr/bin/swift",
            arguments: ["build"] + arguments,
            currentDirectory: root
        )

        // Combine stdout and stderr since Swift outputs diagnostics to stderr
        let combinedOutput = result.stdout + "\n" + result.stderr

        return (combinedOutput, result.exitCode)
    }
}
