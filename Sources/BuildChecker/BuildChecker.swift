import Foundation
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

    /// What starts `swift build`, reads the clock around it and samples the load after it.
    private let launcher: ToolLauncher

    /// Creates a new BuildChecker instance.
    public init() {
        self.init(launcher: .live)
    }

    /// Creates a checker whose tool launches go through `launcher`.
    ///
    /// - Parameter launcher: What starts `swift build`. Replaceable so a test can decide the
    ///   exit code, the elapsed time and the load without compiling anything.
    init(launcher: ToolLauncher) {
        self.launcher = launcher
    }

    /// Declares no cache inputs: a `build` verdict is never replayed from the result cache.
    ///
    /// It used to declare the whole source tree, on the reasoning that "does this package
    /// compile" is a function of the sources and the manifests. Two real inputs were missing
    /// from that fingerprint, and each made the cache wrong in its own direction:
    ///
    /// - **The build directory.** A warm build prints no warnings, so whether the stored verdict
    ///   was a pass or a warning depended on what `.build` looked like when it was written.
    /// - **Local path dependencies.** They are compiled, their warnings are reported, and they
    ///   live outside the project root — so a warning fixed in a sibling package was replayed
    ///   on every cached run until the build directory was deleted.
    ///
    /// Either could be patched into the fingerprint, and the next missing input (SDK,
    /// environment, an `-Xswiftc` in the shell) would be found the same way those were. The
    /// build system already tracks all of them, per file, and answers a no-op build in a few
    /// seconds; with the recorded diagnostics read after it, that warm build is a complete
    /// answer. So the build system is the cache, and the gate keeps no copy in front of it.
    ///
    /// A side effect worth having: with no hits, `.build` is populated whenever `build` has
    /// run, which is what the index-backed checkers and the test runner want to be true.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        nil
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
        let run = try runSwiftBuild(arguments: args, in: projectRoot, configuration: configuration)
        let exitCode = run.exitCode

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
        return Self.createResult(
            run: run, duration: duration, recorded: recorded, projectRoot: projectRoot)
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
        canonicalisingCategories(ToolRun.removingTerminalEscapes(text))
    }

    /// Rewrites every `[#group]` in printed output to the one spelling a recorded diagnostic
    /// uses.
    ///
    /// The comment above says the printed and recorded forms must compare equal, and on Darwin
    /// they do: the compiler emits the group as an OSC 8 hyperlink whose display text is
    /// `NoUsage`, so stripping the escapes leaves exactly what the `.dia` record renders.
    ///
    /// Off Darwin there is no hyperlink. The transcript carries the slug — `no-usage` — while
    /// the record carries the group name, so the two stopped comparing equal and **every
    /// warning that was both printed and recorded was reported twice**. Five `WarmBuildTests`
    /// failures on each Linux leg, all of them duplication rather than absence.
    ///
    /// That was a regression introduced by canonicalising the reader alone. Before it, both
    /// sides said `no-usage`: wrong against the tests' expectation, but equal to each other, so
    /// dedup held. Normalising one of two paths that exist precisely to be compared is worse
    /// than normalising neither — the invariant was equality, and the fix broke it while
    /// improving one side.
    private static func canonicalisingCategories(_ text: String) -> String {
        guard text.contains("[#") else { return text }
        // A literal pattern that fails to compile cannot be repaired at run time, and returning
        // the text unchanged loses deduplication rather than the diagnostic.
        // silent: a literal pattern cannot fail to compile; unchanged text loses only deduplication
        guard let pattern = try? NSRegularExpression(pattern: "\\[#([A-Za-z0-9-]+)\\]") else {
            return text
        }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = text
        // Reverse order so each replacement leaves the earlier ranges valid.
        for match in pattern.matches(in: text, range: full).reversed() {
            guard match.numberOfRanges == 2,
                  let whole = Range(match.range(at: 0), in: text),
                  let group = Range(match.range(at: 1), in: text) else { continue }
            let canonical = SerializedDiagnosticsReader.canonicalCategory(String(text[group]))
            result.replaceSubrange(whole, with: "[#\(canonical)]")
        }
        return result
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
    ///   - projectRoot: The package root, so a path inside it is judged by what follows it;
    ///     `nil` judges each path as written.
    /// - Returns: A CheckResult summarizing the build
    public static func createResult(
        output: String,
        exitCode: Int32,
        duration: Duration,
        recorded: RecordedDiagnostics? = nil,
        projectRoot: String? = nil
    ) -> CheckResult {
        createResult(
            run: ToolRun(
                transcriptOf: "swift build", checkerId: "build",
                output: output, exitCode: exitCode, elapsed: duration),
            duration: duration, recorded: recorded, projectRoot: projectRoot)
    }

    /// Create a CheckResult from a run of `swift build` and the compiler's recorded
    /// diagnostics.
    ///
    /// As ``createResult(output:exitCode:duration:recorded:projectRoot:)``, with the record of
    /// the launch: a build stopped at its budget is reported as `build-timeout`, and a build
    /// that failed without a compiler diagnostic as `build-unparsed-failure`, each naming the
    /// budget, the elapsed time and the machine's load.
    ///
    /// - Parameters:
    ///   - run: What launching `swift build` produced.
    ///   - duration: How long the checker took.
    ///   - recorded: The recorded diagnostics read after a successful build, or `nil` to judge
    ///     the transcript alone.
    ///   - projectRoot: The package root, so a path inside it is judged by what follows it;
    ///     `nil` judges each path as written.
    /// - Returns: A CheckResult summarizing the build
    public static func createResult(
        run: ToolRun,
        duration: Duration,
        recorded: RecordedDiagnostics? = nil,
        projectRoot: String? = nil
    ) -> CheckResult {
        let output = run.output
        let exitCode = run.exitCode
        let succeeded = exitCode == 0
        // Scoped to first-party source *before* the verdict is reached, not while the result
        // is assembled. The status used to be computed from every parsed diagnostic and the
        // dependency warnings dropped afterwards, so a clean build of a package whose
        // dependency warns was `WARNING` with no warning in it — and the gate, finding that,
        // added `[build] reported WARNING without a warning-severity finding`. A cold build
        // showed it and a warm one did not, because a warm build does not recompile the
        // dependency and so prints nothing to mis-count.
        let scope = uniqued(parseBuildOutput(output) + (succeeded ? recorded?.diagnostics ?? [] : []))
            .firstPartyScope(projectRoot: projectRoot)
        var diagnostics = scope.counted
        // The checker's own statements about what it read, which first-party scoping — a
        // question about where a compiler diagnostic points — has nothing to say about. The
        // scoping note leads them: it is why the count above is what it is.
        var coverage: [Diagnostic] = scope.note.map { [$0] } ?? []

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
            // A build that was terminated at its budget did not succeed, whatever its output
            // mentions, and it is reported as that and nothing else. `test` learned the first
            // half the hard way — a cut-off run reported as passed with a signing warning —
            // and this checker learned the second: "exit 124, no parseable diagnostic" is
            // true, and is not what happened.
            if run.expired {
                status = .failed
                diagnostics.append(run.expiryDiagnostic())
            } else if !hasCompilationErrors && isCodeSigningError(output) {
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
                // a manifest that will not evaluate, a dependency that will not check out —
                // and those parse to nothing. The result was then `.failed` with an empty
                // diagnostics array, so the gate printed `✗ [build] FAILED (72.32s)` and not
                // one word about why.
                //
                // Observed 2026-08-17: a test target missing a dependency took the gate red, and
                // the cause was only found by running `swift build --build-tests` by hand. The
                // checker that exists to surface compiler output had surfaced none of it.
                //
                // The tail alone was not enough either. SwiftPM reports a failed checkout once
                // and then prints a screen of progress, so the last twenty lines of a fresh
                // worktree's first build inside a hook were twenty lines of "Fetching" — the
                // `error:` line is now quoted wherever it fell.
                if diagnostics.isEmpty {
                    diagnostics.append(run.unparsedFailureDiagnostic(ruleId: "build-unparsed-failure"))
                }
            }
        }

        return CheckResult(
            checkerId: "build",
            status: status,
            diagnostics: diagnostics + coverage,
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

    /// The environment for the spawned `swift build`: this process's, without the
    /// repository git scoped to a hook.
    ///
    /// `swift build` resolves dependencies by running git, and that git obeys `GIT_DIR`.
    /// Inherited from a hook of a linked worktree, it turns a first build into `Couldn’t
    /// check out revision … fatal: unable to read tree`. See `ChildProcessEnvironment`
    /// for the measurements, and for what is removed and what is kept.
    static func childEnvironment(from parent: [String: String]) -> [String: String] {
        ChildProcessEnvironment.withoutGitRepositoryScope(parent)
    }

    /// Runs `swift build` under the checker's budget and records the run.
    ///
    /// The budget is `budgets.build` when the configuration sets one, and otherwise follows
    /// the last successful build recorded for this package — three times that, never less
    /// than 900 seconds, and 3,600 for a tree with no record, which is a cold one. It was the
    /// process runner's 600 seconds, a figure chosen for `git rev-parse`.
    private func runSwiftBuild(
        arguments: [String], in root: String, configuration: Configuration
    ) throws -> ToolRun {
        // SAFETY: runs swift build to check compilation
        let run = try launcher.run(ToolLauncher.Request(
            checkerId: id,
            executable: "/usr/bin/swift",
            arguments: ["build"] + arguments,
            directory: root,
            environment: Self.childEnvironment(from: ProcessInfo.processInfo.environment),
            budget: CheckerBudget.allowance(for: id, root: root, configuration: configuration)))

        // Only a success says how long the build takes when it works.
        if run.exitCode == 0 {
            CheckerBudget.record(run.elapsed, named: id, root: root)
        }
        return run
    }
}
