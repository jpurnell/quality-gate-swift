import Foundation
#if canImport(os)
import os
#endif
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
    private static let logger = Logger(subsystem: "com.quality-gate", category: "XcodeBuildChecker")

    /// Unique identifier for this checker.
    public let id = "xcode-build"

    /// Human-readable name for this checker.
    public let name = "Xcode Build Checker"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Xcode project build validation and IndexStore generation (opt-in)"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.specialty

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
    /// Spawns `xcodebuild`, which locks the build tree — must run sequentially,
    /// outside the concurrent task group.
    public var isParallelSafe: Bool { false }

    /// Creates a new XcodeBuildChecker instance.
    public init() {}

    /// Whether a destination's build should be treated as failed.
    ///
    /// The exit code decides this on its own. Parsing decides *what to report*, never
    /// *whether it failed*: this previously required a nonzero exit **and** a parsed
    /// `.error`, so a compiler diagnostic in a format the parser did not recognise —
    /// Xcode 27's, as it turned out — turned a failing build into `✓ PASSED`. An exit
    /// code we cannot explain is precisely the case that must not pass quietly.
    static func buildFailed(exitCode: Int32, diagnostics: [Diagnostic]) -> Bool {
        exitCode != 0
    }

    /// A diagnostic for a build that failed without any recognisable compiler output.
    ///
    /// Carries the tail of what xcodebuild actually printed, because the reason the
    /// parser missed it is the reason a human needs to read it.
    static func unexplainedFailureDiagnostic(
        exitCode: Int32,
        destination: String,
        output: String
    ) -> Diagnostic {
        let tail = output
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .suffix(20)
            .joined(separator: "\n")
        return Diagnostic(
            severity: .error,
            message: """
                xcodebuild exited \(exitCode) for \(destination), and none of its output \
                matched a diagnostic this checker knows how to parse. The build failed; \
                the last lines of its output follow.

                \(tail)
                """,
            ruleId: "xcode-build-unexplained-failure",
            suggestedFix: "Run the same xcodebuild invocation directly to see the full output."
        )
    }

    /// The scheme to build, given everything `xcodebuild -list` reported.
    ///
    /// `schemes.first` was wrong whenever the project has Swift package dependencies.
    /// Xcode lists a scheme for every resolved package alongside the project's own, and
    /// a dependency often sorts first: `WineTaster 4` reports
    /// `["BusinessMath", "BusinessMath-Package", "WineTaster 4"]`. The checker built
    /// `BusinessMath` — a dependency that compiles cleanly — reported `✓ PASSED`, and
    /// never compiled a line of the app under test. A build checker that quietly builds
    /// something else is worse than none, because the green tick is what stops you looking.
    ///
    /// The container's own name is the scheme belonging to it. Anything else is a guess,
    /// so the first entry stays the fallback for projects that name schemes differently.
    static func preferredScheme(schemes: [String], containerName: String?) -> String? {
        if let containerName, schemes.contains(containerName) { return containerName }
        return schemes.first
    }

    /// The generic destination for the platforms a scheme can actually build.
    ///
    /// `SUPPORTED_PLATFORMS` is a space-separated list of SDK names, which is what
    /// `xcodebuild -showBuildSettings` reports and not what `-destination` accepts — hence
    /// the mapping. Both the device and simulator SDK of a family point at the same generic
    /// destination, because a generic destination names the family.
    ///
    /// The host wins when the scheme supports it: `generic/platform=macOS` needs neither a
    /// booted simulator nor a signing identity, so it is the cheapest true answer. It is
    /// only ever returned when the scheme genuinely lists `macosx`.
    ///
    /// - Returns: The destination, or `nil` when the platforms are unrecognised or absent —
    ///   which the caller treats as "could not tell" and falls back to its previous default.
    ///   A guess here would fail a project for a reason this checker invented.
    static func defaultDestination(supportedPlatforms: String) -> String? {
        let sdks = Set(supportedPlatforms.split(separator: " ").map(String.init))
        // Ordered: the first family the scheme supports wins, host first.
        //
        // Device families resolve to their *Simulator* destination, which is the whole
        // point: `generic/platform=iOS` demands a signing identity, and a checker that
        // answers "does this compile" has no business requiring a development team. It
        // failed IconquerApp with `Signing for "iConquer_iOS" requires a development
        // team` — true, irrelevant, and fatal on any machine without the team configured,
        // which includes every CI runner. The simulator destination needs no identity and
        // no device, making it the exact analogue of bare macOS for the host.
        //
        // Chosen over forcing `CODE_SIGNING_ALLOWED=NO`, which would override the
        // project's own signing settings to ask the same question.
        let families: [(platform: String, sdks: Set<String>)] = [
            ("macOS", ["macosx"]),
            ("iOS Simulator", ["iphoneos", "iphonesimulator"]),
            ("tvOS Simulator", ["appletvos", "appletvsimulator"]),
            ("watchOS Simulator", ["watchos", "watchsimulator"]),
            ("visionOS Simulator", ["xros", "xrsimulator"]),
        ]
        for family in families where !family.sdks.isDisjoint(with: sdks) {
            return "generic/platform=\(family.platform)"
        }
        return nil
    }

    /// Run xcodebuild for each configured destination and collect diagnostics.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let config = configuration.xcodeBuild

        let projectArgs = try resolveProjectArguments(config, root: configuration.resolvedProjectRoot.path)

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

        let scheme = try config.scheme ?? discoverScheme(
            projectArgs: projectArgs, root: configuration.resolvedProjectRoot.path)

        // Ask the scheme what it can build before assuming the host. A blind
        // `generic/platform=macOS` reported `xcodebuild exited 70` and a wall of
        // destination noise for IconquerApp, whose only fault was being an iOS app: it
        // declares one scheme per platform, so `preferredScheme` picked `iConquer_iOS` and
        // this line asked for a Mac. An explicit `destinations:` still wins — the author
        // has said what they want, and this must not second-guess it.
        let destinations: [String]
        if config.destinations.isEmpty {
            let discovered = discoverDestination(
                projectArgs: projectArgs,
                scheme: scheme,
                root: configuration.resolvedProjectRoot.path)
            destinations = [discovered ?? "generic/platform=macOS"]
        } else {
            destinations = config.destinations
        }

        var allDiagnostics: [Diagnostic] = []
        var anyBuildFailed = false

        for destination in destinations {
            var args = ["build"]
            args.append(contentsOf: projectArgs)
            args.append(contentsOf: ["-scheme", scheme])
            args.append(contentsOf: ["-destination", destination])
            args.append("-quiet")
            // Opt-in, and off by default on purpose: skipping validation means the build
            // executes a package's plugin code without the trust check Xcode would
            // otherwise insist on interactively. A gate cannot answer that prompt, so a
            // project depending on such a package fails with `exit code 1 but produced no
            // further output` until its own config says it accepts the trade.
            if config.skipPluginValidation {
                args.append(contentsOf: ["-skipPackagePluginValidation", "-skipMacroValidation"])
            }

            // SAFETY: runs xcodebuild to check compilation
            let result = try ProcessRunner.run(
                "/usr/bin/xcodebuild",
                arguments: args,
                currentDirectory: configuration.resolvedProjectRoot.path
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

            if Self.buildFailed(exitCode: result.exitCode, diagnostics: diagnostics) {
                anyBuildFailed = true
                // A failure the parser could not explain still has to be visible. Without
                // this the run reports a failing build with no diagnostics attached, which
                // reads exactly like a clean one.
                if !diagnostics.contains(where: { $0.severity == .error }) {
                    allDiagnostics.append(Self.unexplainedFailureDiagnostic(
                        exitCode: result.exitCode,
                        destination: destination,
                        output: combinedOutput
                    ))
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
        _ config: XcodeBuildCheckerConfig,
        root: String
    ) throws -> [String]? {
        if let workspace = config.workspace {
            return ["-workspace", workspace]
        }
        if let project = config.project {
            return ["-project", project]
        }

        // SAFETY: CLI reads local cwd directory listing for Xcode project auto-discovery
        let contents = try FileManager.default.contentsOfDirectory(atPath: root)

        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return ["-workspace", workspace]
        }
        if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return ["-project", project]
        }

        return nil
    }

    private func discoverScheme(projectArgs: [String], root: String) throws -> String {
        var args = ["-list", "-json"]
        args.append(contentsOf: projectArgs)

        // SAFETY: runs xcodebuild -list to discover available schemes
        let result = try ProcessRunner.run(
            "/usr/bin/xcodebuild",
            arguments: args,
            currentDirectory: root
        )

        guard result.exitCode == 0 else {
            throw QualityGateError.configurationError(
                "xcodebuild -list failed: \(result.stderr)"
            )
        }

        guard let data = result.stdout.data(using: .utf8) else {
            throw QualityGateError.configurationError(
                "Failed to parse xcodebuild -list output"
            )
        }
        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw QualityGateError.configurationError(
                    "Failed to parse xcodebuild -list output"
                )
            }
            json = parsed
        } catch {
            Self.logger.warning("Failed to parse xcodebuild -list JSON: \(error.localizedDescription, privacy: .public)")
            throw QualityGateError.configurationError(
                "Failed to parse xcodebuild -list output"
            )
        }

        let schemesContainer = (json["project"] as? [String: Any])
            ?? (json["workspace"] as? [String: Any])

        guard let schemes = schemesContainer?["schemes"] as? [String],
              let scheme = Self.preferredScheme(
                schemes: schemes,
                containerName: schemesContainer?["name"] as? String
              ) else {
            throw QualityGateError.configurationError(
                "No schemes found in Xcode project"
            )
        }

        return scheme
    }

    /// The destination the scheme's own build settings imply, or `nil` when they cannot
    /// be read.
    ///
    /// Failure is deliberately quiet: this runs to *improve* on a default, so a project
    /// whose settings cannot be read is left exactly where it was rather than failed for
    /// the reading. `-showBuildSettings` is asked for one scheme, and the first entry that
    /// carries `SUPPORTED_PLATFORMS` answers the question.
    private func discoverDestination(
        projectArgs: [String], scheme: String, root: String
    ) -> String? {
        var args = ["-showBuildSettings", "-json"]
        args.append(contentsOf: projectArgs)
        args.append(contentsOf: ["-scheme", scheme])

        let result: ProcessRunner.Output
        do {
            // SAFETY: reads the scheme's platforms via -showBuildSettings
            result = try ProcessRunner.run(
                "/usr/bin/xcodebuild", arguments: args, currentDirectory: root)
        } catch {
            // Quiet, not invisible: the caller keeps its default destination either way,
            // but "xcodebuild would not run" and "the scheme names no platforms" are
            // different facts and used to be indistinguishable from outside.
            Self.logger.debug(
                "xcode-build could not run -showBuildSettings for scheme \(scheme, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8) else {
            Self.logger.debug(
                "xcode-build got exit \(result.exitCode, privacy: .public) from -showBuildSettings for scheme \(scheme, privacy: .public)")
            return nil
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            Self.logger.debug(
                "xcode-build could not parse -showBuildSettings JSON for scheme \(scheme, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let entries = parsed as? [[String: Any]] else { return nil }

        for entry in entries {
            guard let settings = entry["buildSettings"] as? [String: Any],
                  let platforms = settings["SUPPORTED_PLATFORMS"] as? String,
                  let destination = Self.defaultDestination(supportedPlatforms: platforms)
            else { continue }
            Self.logger.debug("xcode-build chose \(destination, privacy: .public) for scheme \(scheme, privacy: .public)")
            return destination
        }
        return nil
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
