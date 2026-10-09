import Foundation
import QualityGateLogging
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
    public let summary = "Xcode build of a project, workspace or Swift package, and IndexStore generation (opt-in)"

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

    /// One launch of `xcodebuild`: what was run, where, and with which environment.
    struct Invocation: Sendable, Equatable {
        /// The arguments after `xcodebuild`.
        let arguments: [String]
        /// The working directory — the project root.
        let directory: String
        /// The complete environment the process is started with.
        let environment: [String: String]
        /// The time budget the launch is given, and where that figure came from.
        let budget: CheckerBudget.Allowance
    }

    /// What a launch of `xcodebuild` produced.
    struct ToolOutput: Sendable, Equatable {
        /// Standard output.
        let stdout: String
        /// Standard error.
        let stderr: String
        /// The exit code.
        let exitCode: Int32
        /// Wall-clock seconds the launch took.
        var elapsed: TimeInterval = 0
        /// The machine's load when it ended, or `nil` if it was not read.
        var load: MachineLoad?
    }

    /// Starts `xcodebuild`. Replaceable so a test can see what would have been launched
    /// without launching it.
    typealias Launcher = @Sendable (Invocation) throws -> ToolOutput

    private let parentEnvironment: @Sendable () -> [String: String]
    private let launcher: Launcher

    /// Creates a new XcodeBuildChecker instance.
    public init() {
        self.init(
            parentEnvironment: { ProcessInfo.processInfo.environment },
            launcher: Self.launchXcodebuild)
    }

    /// Creates a checker with its environment and launcher supplied.
    ///
    /// - Parameters:
    ///   - parentEnvironment: The environment this process is running in.
    ///   - launcher: What starts `xcodebuild`.
    init(
        parentEnvironment: @escaping @Sendable () -> [String: String],
        launcher: @escaping Launcher
    ) {
        self.parentEnvironment = parentEnvironment
        self.launcher = launcher
    }

    /// The environment `xcodebuild` is started with: this process's, without the
    /// repository git scoped to a hook.
    ///
    /// `xcodebuild` resolves package dependencies by running git, and that git obeys
    /// `GIT_DIR`. Inside the pre-push hook of a linked worktree `GIT_DIR` names the main
    /// repository's `worktrees/<name>`, so every dependency checkout was attempted against
    /// the project instead of the dependency and `-list` failed with `Couldn’t check out
    /// revision` — in the hook only, and only until something else had resolved the
    /// packages. See `ChildProcessEnvironment` for what is removed and what is kept.
    static func childEnvironment(from parent: [String: String]) -> [String: String] {
        ChildProcessEnvironment.withoutGitRepositoryScope(parent)
    }

    /// Runs the real `xcodebuild`.
    private static func launchXcodebuild(_ invocation: Invocation) throws -> ToolOutput {
        // SAFETY: runs xcodebuild, a hardcoded system path, to list schemes, read build settings and check compilation
        let run = try ToolLauncher.live.run(ToolLauncher.Request(
            checkerId: "xcode-build",
            executable: "/usr/bin/xcodebuild",
            arguments: invocation.arguments,
            directory: invocation.directory,
            environment: invocation.environment,
            budget: invocation.budget))
        return ToolOutput(
            stdout: run.stdout, stderr: run.stderr, exitCode: run.exitCode,
            elapsed: run.elapsed, load: run.load)
    }

    /// One launch of `xcodebuild` together with what it produced.
    private struct Launch {
        /// What was started.
        let invocation: Invocation
        /// What it produced.
        let output: ToolOutput

        /// The launch as the shared record every budgeted checker reports from.
        var run: ToolRun {
            ToolRun(
                checkerId: "xcode-build",
                command: (["xcodebuild"] + invocation.arguments).joined(separator: " "),
                directory: invocation.directory,
                stdout: output.stdout,
                stderr: output.stderr,
                exitCode: output.exitCode,
                budget: invocation.budget,
                elapsed: output.elapsed,
                load: output.load)
        }
    }

    /// Launches `xcodebuild` in `root` with ``childEnvironment(from:)``, under `budget`.
    private func xcodebuild(
        _ arguments: [String], in root: String, budget: CheckerBudget.Allowance
    ) throws -> Launch {
        let invocation = Invocation(
            arguments: arguments,
            directory: root,
            environment: Self.childEnvironment(from: parentEnvironment()),
            budget: budget)
        return Launch(invocation: invocation, output: try launcher(invocation))
    }

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

    /// The checker's status: failed if any destination failed, otherwise a warning if the
    /// compiler warned, otherwise passed.
    ///
    /// Warnings used to leave the status `.passed`, so a watchOS-only warning showed up in
    /// the summary count while the checker's line stayed green.
    static func status(anyBuildFailed: Bool, diagnostics: [Diagnostic]) -> CheckResult.Status {
        if anyBuildFailed { return .failed }
        return diagnostics.contains { $0.severity == .warning } ? .warning : .passed
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

    /// A diagnostic for an `xcodebuild -list` that failed — before any build was attempted.
    ///
    /// This used to be thrown as `QualityGateError.configurationError`, which the runner
    /// printed as `Checker failed: Configuration error: xcodebuild -list failed: …` beside a
    /// duration of `0ms`. Each part pointed somewhere wrong: the checker had not failed, the
    /// configuration was not at fault, and `xcodebuild` had run for seconds. So the finding
    /// now says what was run, where, how it exited, and — when the output shows it — that
    /// the failure was `xcodebuild` resolving package dependencies rather than anything in
    /// the project's own sources.
    ///
    /// - Parameters:
    ///   - arguments: What was passed to `xcodebuild`.
    ///   - directory: Where it was run.
    ///   - exitCode: How it exited.
    ///   - output: What it printed; the last twenty lines are quoted.
    static func listFailureDiagnostic(
        arguments: [String],
        directory: String,
        exitCode: Int32,
        output: String
    ) -> Diagnostic {
        let command = (["xcodebuild"] + arguments).joined(separator: " ")
        let tail = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .suffix(20)
            .joined(separator: "\n")
        let ran = "`\(command)` exited \(exitCode) in \(directory)"

        guard output.contains("Could not resolve package dependencies") else {
            return Diagnostic(
                severity: .error,
                message: """
                    \(ran), so there is no scheme to build. Nothing was compiled; the last \
                    lines of its output follow.

                    \(tail)
                    """,
                ruleId: "xcode-build-list-failed",
                suggestedFix: "Run `\(command)` in \(directory) to see the full output."
            )
        }
        return Diagnostic(
            severity: .error,
            message: """
                \(ran) while resolving package dependencies — xcodebuild's own step, which \
                clones and checks out each dependency before it can list a scheme. Nothing \
                was compiled, and this is not a finding about the project's sources; the \
                last lines of its output follow.

                \(tail)
                """,
            ruleId: "xcode-build-package-resolution",
            suggestedFix: "Run `\(command)` in \(directory) to see the full output; `xcodebuild -resolvePackageDependencies` there retries the resolution on its own."
        )
    }

    /// `xcodebuild -list` exited nonzero. Carries the finding to report in its place.
    private struct ListFailure: Error {
        let diagnostic: Diagnostic
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

        // Nothing built is `.skipped`, never `.passed`. It used to pass: a plain package,
        // configured with a scheme and a watchOS destination, printed `✓ PASSED (0ms)`
        // having compiled nothing — the green tick `BuildVerdictTests` exists to prevent.
        guard let projectArgs else {
            let duration = ContinuousClock.now - startTime
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No Xcode workspace, Xcode project or Package.swift found — nothing to build",
                        ruleId: "xcode-build-skip"
                    )
                ],
                duration: duration
            )
        }

        // Every launch runs under the same budget: `budgets.xcode-build` when it is set, the
        // process runner's default otherwise. No history is kept for this checker — its
        // products live in DerivedData, and a duration file would have to be written into a
        // project that may have no ignored build directory to hold it.
        let budget = CheckerBudget.fixedAllowance(for: id, configuration: configuration)

        let scheme: String
        do {
            scheme = try config.scheme ?? discoverScheme(
                projectArgs: projectArgs, root: configuration.resolvedProjectRoot.path, budget: budget)
        } catch let failure as ListFailure {
            // A result, not a throw: the tool ran and its answer is a finding. Thrown, it
            // surfaced as `Checker failed: Configuration error` after `0ms`.
            Self.logger.error("xcodebuild -list failed; reporting \(failure.diagnostic.ruleId ?? "", privacy: .public)")
            return CheckResult(
                checkerId: id,
                status: .failed,
                diagnostics: [failure.diagnostic],
                duration: ContinuousClock.now - startTime
            )
        }

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
                root: configuration.resolvedProjectRoot.path,
                budget: budget)
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

            let launch = try xcodebuild(
                args, in: configuration.resolvedProjectRoot.path, budget: budget)
            let result = launch.output

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

            if launch.run.expired {
                // Asked before the exit code is read as a build failure: a build that was
                // stopped has not failed to compile, and "exited 124 … matched no diagnostic"
                // sends the reader looking for an error that is not there.
                anyBuildFailed = true
                allDiagnostics.append(launch.run.expiryDiagnostic())
            } else if Self.buildFailed(exitCode: result.exitCode, diagnostics: diagnostics) {
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

        let verdict = Self.verdict(
            diagnostics: allDiagnostics,
            anyBuildFailed: anyBuildFailed,
            projectRoot: configuration.resolvedProjectRoot.path
        )
        let duration = ContinuousClock.now - startTime

        return CheckResult(
            checkerId: id,
            status: verdict.status,
            diagnostics: verdict.diagnostics,
            duration: duration
        )
    }

    /// The status and the diagnostics to report, from everything the builds printed.
    ///
    /// Repeats are removed, then warnings and notes in a dependency are scoped out — the
    /// same rule `build` and `doc-lint` apply, from the same definition
    /// (`DependencyOrigin`). It was not applied here at all: Xcode keeps a checkout under
    /// `DerivedData/<project>/SourcePackages/checkouts/`, so mlx-swift's Metal shader headers
    /// put 20 `-Wc++17-extensions` warnings on every clean build of a package that merely
    /// depends on it, while `build` dropped the same warnings from `.build/checkouts/`.
    ///
    /// The status is computed from what is left, so it cannot say `WARNING` over a result
    /// with no warning in it. Errors are never scoped: a dependency that fails to build fails
    /// the gate, and says why. What was scoped out is counted in a closing note.
    ///
    /// - Parameters:
    ///   - diagnostics: Every diagnostic parsed from every destination, in order.
    ///   - anyBuildFailed: Whether any destination's `xcodebuild` exited nonzero.
    ///   - projectRoot: The root of the project under audit.
    /// - Returns: The checker's status and the diagnostics its result carries.
    static func verdict(
        diagnostics: [Diagnostic],
        anyBuildFailed: Bool,
        projectRoot: String
    ) -> (status: CheckResult.Status, diagnostics: [Diagnostic]) {
        let scope = dedup(diagnostics).firstPartyScope(projectRoot: projectRoot)
        return (status(anyBuildFailed: anyBuildFailed, diagnostics: scope.counted), scope.reported)
    }

    // MARK: - Private

    private func resolveProjectArguments(
        _ config: XcodeBuildCheckerConfig,
        root: String
    ) throws -> [String]? {
        if config.workspace != nil || config.project != nil {
            return Self.projectArguments(config: config, directoryContents: [])
        }
        // SAFETY: CLI reads local cwd directory listing for Xcode project auto-discovery
        let contents = try FileManager.default.contentsOfDirectory(atPath: root)
        return Self.projectArguments(config: config, directoryContents: contents)
    }

    /// The container arguments `xcodebuild` needs, or `nil` when there is nothing to build.
    ///
    /// Configured workspace, then configured project, then a discovered `.xcworkspace`,
    /// then a discovered `.xcodeproj` — and, failing all four, a `Package.swift`, which
    /// needs **no** container arguments: `xcodebuild` builds a package from its own
    /// directory. A project or workspace beside a `Package.swift` still wins, so nothing
    /// that built before builds something different now.
    ///
    /// - Parameters:
    ///   - config: The checker's configuration.
    ///   - directoryContents: Entry names in the project root (sorted for determinism).
    /// - Returns: The arguments, possibly empty for a package; `nil` for nothing to build.
    static func projectArguments(
        config: XcodeBuildCheckerConfig,
        directoryContents: [String]
    ) -> [String]? {
        if let workspace = config.workspace {
            return ["-workspace", workspace]
        }
        if let project = config.project {
            return ["-project", project]
        }
        let contents = directoryContents.sorted()
        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return ["-workspace", workspace]
        }
        if let project = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return ["-project", project]
        }
        if contents.contains("Package.swift") {
            return []
        }
        return nil
    }

    private func discoverScheme(
        projectArgs: [String], root: String, budget: CheckerBudget.Allowance
    ) throws -> String {
        var args = ["-list", "-json"]
        args.append(contentsOf: projectArgs)

        let launch = try xcodebuild(args, in: root, budget: budget)
        let result = launch.output

        // A listing that was stopped is not a listing that failed: the remedy is a rerun or
        // a larger budget, not `-resolvePackageDependencies`.
        guard !launch.run.expired else {
            throw ListFailure(diagnostic: launch.run.expiryDiagnostic())
        }

        guard result.exitCode == 0 else {
            throw ListFailure(diagnostic: Self.listFailureDiagnostic(
                arguments: args,
                directory: root,
                exitCode: result.exitCode,
                output: result.stderr))
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
        projectArgs: [String], scheme: String, root: String, budget: CheckerBudget.Allowance
    ) -> String? {
        var args = ["-showBuildSettings", "-json"]
        args.append(contentsOf: projectArgs)
        args.append(contentsOf: ["-scheme", scheme])

        let result: ToolOutput
        do {
            result = try xcodebuild(args, in: root, budget: budget).output
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

    private static func dedup(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        var seen = Set<String>()
        return diagnostics.filter { diag in
            let key = "\(diag.filePath ?? ""):\(diag.lineNumber ?? 0):\(diag.message)"
            return seen.insert(key).inserted
        }
    }
}
