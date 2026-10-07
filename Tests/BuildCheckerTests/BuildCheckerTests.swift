import Foundation
import Testing
@testable import BuildChecker
@testable import QualityGateCore

/// Tests for BuildChecker.
///
/// BuildChecker executes `swift build` and parses compiler output into
/// structured diagnostics. These tests verify output parsing and result generation.
@Suite("BuildChecker Tests")
struct BuildCheckerTests {

    // MARK: - Identity Tests

    @Test("BuildChecker has correct id and name")
    func checkerIdentity() {
        let checker = BuildChecker()
        #expect(checker.id == "build")
        #expect(checker.name == "Build Checker")
    }

    // MARK: - Output Parsing Tests

    @Test("Parses error with file location")
    func parsesErrorWithLocation() throws {
        let output = """
        /path/to/File.swift:42:15: error: cannot find 'foo' in scope
            let x = foo
                    ^~~
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        #expect(diagnostics.count == 1)
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.filePath == "/path/to/File.swift")
        #expect(diagnostic.lineNumber == 42)
        #expect(diagnostic.columnNumber == 15)
        #expect(diagnostic.message.contains("cannot find 'foo' in scope"))
    }

    @Test("Parses warning with file location")
    func parsesWarningWithLocation() throws {
        let output = """
        /path/to/File.swift:10:5: warning: variable 'x' was never used
            let x = 5
                ^
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        #expect(diagnostics.count == 1)
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.filePath == "/path/to/File.swift")
        #expect(diagnostic.lineNumber == 10)
        #expect(diagnostic.columnNumber == 5)
        #expect(diagnostic.message.contains("variable 'x' was never used"))
    }

    /// Every other parse test in this file feeds in plain text, which is why this
    /// went unnoticed: `swift build` colourises diagnostics even through a pipe, so
    /// the real severity token arrives wrapped in SGR escapes —
    /// `File.swift:140:17: ESC[1;33mwarning: ESC[1;39mmessage`. The pattern expects
    /// `: warning: ` with nothing between, so it matched nothing at all, and the
    /// checker reported a clean build while the compiler was printing warnings.
    @Test("Parses diagnostics that arrive with ANSI colour escapes")
    func parsesColourisedDiagnostics() {
        let esc = "\u{1B}"
        let output = """
        /path/to/File.swift:140:17: \(esc)[1;33mwarning: \(esc)[1;39m'chi2cdf(x:dF:)' is deprecated: use chiSquaredCDF\(esc)[0;0m
        /path/to/Other.swift:42:15: \(esc)[1;31merror: \(esc)[1;39mcannot find 'foo' in scope\(esc)[0;0m
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        #expect(diagnostics.count == 2)

        let warning = diagnostics.first { $0.severity == .warning }
        #expect(warning?.filePath == "/path/to/File.swift")
        #expect(warning?.lineNumber == 140)
        #expect(warning?.columnNumber == 17)
        #expect(warning?.message.contains("is deprecated") == true)
        // The message must not carry the escapes through into reports.
        #expect(warning?.message.contains(esc) == false)

        let error = diagnostics.first { $0.severity == .error }
        #expect(error?.filePath == "/path/to/Other.swift")
        #expect(error?.lineNumber == 42)
        #expect(error?.message.contains("cannot find 'foo' in scope") == true)
    }

    @Test("Parses note with file location")
    func parsesNoteWithLocation() throws {
        let output = """
        /path/to/File.swift:5:10: note: 'foo' declared here
            func foo() {}
                 ^~~
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        #expect(diagnostics.count == 1)
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.severity == .note)
        #expect(diagnostic.filePath == "/path/to/File.swift")
        #expect(diagnostic.lineNumber == 5)
        #expect(diagnostic.columnNumber == 10)
    }

    @Test("Parses multiple diagnostics")
    func parsesMultipleDiagnostics() {
        let output = """
        /path/to/A.swift:10:5: error: type 'Foo' has no member 'bar'
        /path/to/B.swift:20:15: warning: result unused
        /path/to/A.swift:12:8: note: did you mean 'baz'?
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        #expect(diagnostics.count == 3)
        #expect(diagnostics.filter { $0.severity == .error }.count == 1)
        #expect(diagnostics.filter { $0.severity == .warning }.count == 1)
        #expect(diagnostics.filter { $0.severity == .note }.count == 1)
    }

    @Test("Parses Swift 6 concurrency warnings")
    func parsesSwift6ConcurrencyWarnings() {
        let output = """
        /path/to/File.swift:15:12: warning: capture of 'self' with non-sendable type 'MyClass' in a `@Sendable` closure
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
        #expect(diagnostics.first?.message.contains("Sendable") == true)
    }

    @Test("Handles empty output")
    func handlesEmptyOutput() {
        let diagnostics = BuildChecker.parseBuildOutput("")
        #expect(diagnostics.isEmpty)
    }

    @Test("Handles output with no diagnostics")
    func handlesCleanBuildOutput() {
        let output = """
        Building for debugging...
        Build complete! (0.50s)
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)
        #expect(diagnostics.isEmpty)
    }

    @Test("Ignores non-diagnostic lines")
    func ignoresNonDiagnosticLines() {
        let output = """
        [1/10] Compiling Module Source.swift
        [2/10] Compiling Module Other.swift
        /path/to/File.swift:42:15: error: something wrong
        [3/10] Linking Module
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .error)
    }

    @Test("Parses paths with spaces")
    func parsesPathsWithSpaces() {
        let output = """
        /Users/name/My Project/Sources/File.swift:10:5: error: missing return
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.filePath == "/Users/name/My Project/Sources/File.swift")
    }

    @Test("Handles Windows-style paths in output")
    func handlesWindowsPaths() {
        // While we primarily target macOS, be resilient to various path formats
        let output = """
        C:\\Users\\name\\Project\\File.swift:10:5: error: missing return
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        // Should still parse the error, even if path format differs
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .error)
    }

    // MARK: - Result Generation Tests

    @Test("Returns passed status for clean build")
    func passedForCleanBuild() async throws {
        // This tests the result generation logic with mocked output
        let result = BuildChecker.createResult(
            output: "Build complete! (0.50s)",
            exitCode: 0,
            duration: .seconds(1)
        )

        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Returns failed status for build errors")
    func failedForBuildErrors() async throws {
        let output = """
        /path/to/File.swift:10:5: error: something wrong
        error: build had 1 command failure
        """

        let result = BuildChecker.createResult(
            output: output,
            exitCode: 1,
            duration: .seconds(2)
        )

        #expect(result.status == .failed)
        #expect(result.diagnostics.count >= 1)
    }

    @Test("Returns warning status for warnings only")
    func warningStatusForWarningsOnly() async throws {
        let output = """
        /path/to/File.swift:10:5: warning: unused variable
        Build complete! (0.50s)
        """

        let result = BuildChecker.createResult(
            output: output,
            exitCode: 0,
            duration: .seconds(1)
        )

        // The build succeeded, but a compiler warning is a finding, and the verdict line
        // must say so. As `.passed` it was counted in the summary and nothing else: the
        // tick stayed green, and a run whose job is "zero warnings" read as clean.
        #expect(result.status == .warning)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.severity == .warning)
    }

    @Test("Result includes checkerId")
    func resultIncludesCheckerId() async throws {
        let result = BuildChecker.createResult(
            output: "",
            exitCode: 0,
            duration: .seconds(1)
        )

        #expect(result.checkerId == "build")
    }

    @Test("Result includes duration")
    func resultIncludesDuration() async throws {
        let result = BuildChecker.createResult(
            output: "",
            exitCode: 0,
            duration: .seconds(5)
        )

        // Duration should be recorded
        #expect(result.duration >= .seconds(0))
    }

    // MARK: - Configuration Tests

    @Test("Uses release configuration when specified")
    func usesReleaseConfiguration() async throws {
        let config = Configuration(buildConfiguration: "release")
        let checker = BuildChecker()

        let args = checker.buildArguments(for: config)

        #expect(args.contains("-c"))
        #expect(args.contains("release"))
    }

    @Test("Uses debug configuration by default")
    func usesDebugByDefault() async throws {
        let config = Configuration()
        let checker = BuildChecker()

        let args = checker.buildArguments(for: config)

        // Debug is the default, may or may not be explicit
        #expect(!args.contains("release"))
    }

    @Test("Includes solver threshold flags when configured")
    func includesThresholdFlags() {
        let config = Configuration(
            build: BuildCheckerConfig(solverExpressionTimeThreshold: 500)
        )
        let checker = BuildChecker()
        let args = checker.buildArguments(for: config)

        #expect(args.contains("-Xswiftc"))
        #expect(args.contains("-Xfrontend"))
        #expect(args.contains("-solver-expression-time-threshold=500"))
    }

    @Test("Omits solver threshold flags when not configured")
    func omitsThresholdByDefault() {
        let config = Configuration()
        let checker = BuildChecker()
        let args = checker.buildArguments(for: config)

        #expect(!args.contains("-Xfrontend"))
        #expect(!args.contains { $0.contains("solver-expression") })
    }

    @Test("Combines build configuration with solver threshold")
    func combinesConfigAndThreshold() {
        let config = Configuration(
            buildConfiguration: "release",
            build: BuildCheckerConfig(solverExpressionTimeThreshold: 250)
        )
        let checker = BuildChecker()
        let args = checker.buildArguments(for: config)

        #expect(args.contains("-c"))
        #expect(args.contains("release"))
        #expect(args.contains("-solver-expression-time-threshold=250"))
    }

    // MARK: - Test-Target Coverage

    /// Without `--build-tests`, `swift build` compiles only the library, so every
    /// diagnostic in the test target is invisible to this checker — while the test
    /// checker compiles those same files moments later and discards their warnings
    /// in favour of test results. A project can sit at "zero warnings" with a test
    /// target full of them, which is what prompted this.
    @Test("Builds the test target by default")
    func buildsTestTargetByDefault() {
        let config = Configuration()
        let checker = BuildChecker()

        let args = checker.buildArguments(for: config)

        #expect(args.contains("--build-tests"))
    }

    @Test("Test target can be excluded explicitly")
    func testTargetCanBeExcluded() {
        let config = Configuration(build: BuildCheckerConfig(includeTests: false))
        let checker = BuildChecker()

        let args = checker.buildArguments(for: config)

        #expect(!args.contains("--build-tests"))
    }

    @Test("Test-target coverage composes with the other build options")
    func testTargetComposesWithOtherOptions() {
        let config = Configuration(
            buildConfiguration: "release",
            build: BuildCheckerConfig(solverExpressionTimeThreshold: 250)
        )
        let checker = BuildChecker()
        let args = checker.buildArguments(for: config)

        #expect(args.contains("--build-tests"))
        #expect(args.contains("release"))
        #expect(args.contains("-solver-expression-time-threshold=250"))
    }

    // MARK: - Code Signing Resilience Tests

    @Test("Passes when only code signing fails")
    func passesOnCodeSigningError() {
        let output = """
        Building for debugging...
        [42/42] Linking quality-gate
        /path/to/.build/debug/quality-gate: internal error in Code Signing subsystem
        """

        let result = BuildChecker.createResult(
            output: output,
            exitCode: 1,
            duration: .seconds(20)
        )

        #expect(result.status == .passed)
        let warnings = result.diagnostics.filter { $0.severity == .warning }
        #expect(warnings.count == 1)
        #expect(warnings.first?.message.contains("code signing") == true)
    }

    @Test("Fails when compilation errors accompany code signing error")
    func failsOnCompilationErrorsWithSigningError() {
        let output = """
        /path/to/File.swift:10:5: error: missing return
        /path/to/.build/debug/quality-gate: internal error in Code Signing subsystem
        """

        let result = BuildChecker.createResult(
            output: output,
            exitCode: 1,
            duration: .seconds(5)
        )

        #expect(result.status == .failed)
    }

    @Test("A build terminated at its time limit fails, even if its output mentions signing")
    func timedOutBuildFails() {
        let output = """
        [1/3] Compiling Example Example.swift
        /path/to/.build/debug/my-tool: codesign failed

        process-kernel: `/usr/bin/swift` timed out after 600s and was terminated.
        """
        let result = BuildChecker.createResult(output: output, exitCode: 124, duration: .seconds(600))
        #expect(result.status == .failed)
        #expect(!result.diagnostics.contains { $0.message.contains("compilation succeeded") })
    }

    @Test("Passes on codesign failed variant")
    func passesOnCodesignFailed() {
        let output = """
        Building for debugging...
        [10/10] Linking my-tool
        /path/to/.build/debug/my-tool: codesign failed
        """

        let result = BuildChecker.createResult(
            output: output,
            exitCode: 1,
            duration: .seconds(3)
        )

        #expect(result.status == .passed)
    }

    // MARK: - Error Message Quality Tests

    @Test("Provides actionable error messages")
    func providesActionableMessages() throws {
        let output = """
        /path/to/File.swift:42:15: error: cannot find 'NetworkManager' in scope
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        let diagnostic = try #require(diagnostics.first)
        // Message should include the original error text
        #expect(diagnostic.message.contains("cannot find") ||
                diagnostic.message.contains("NetworkManager"))
    }

    // MARK: - Hyperlink Escapes

    @Test("An OSC 8 hyperlink around the diagnostic group is removed from the message")
    func stripsHyperlinkEscapes() throws {
        // Exactly what Swift 6.4 prints through a pipe: SGR colour around the severity, and the
        // diagnostic group wrapped in an OSC 8 hyperlink to its documentation.
        let esc = "\u{1B}"
        let output = "/path/to/Warns.swift:6:9: \(esc)[1;33mwarning: \(esc)[1;39mresult of call to 'loud()' is unused\(esc)[0;0m "
            + "[#\(esc)]8;;https://docs.swift.org/compiler/documentation/diagnostics/no-usage\(esc)\\NoUsage\(esc)]8;;\(esc)\\]"

        let diagnostic = try #require(BuildChecker.parseBuildOutput(output).first)

        #expect(diagnostic.message == "result of call to 'loud()' is unused [#NoUsage]")
        #expect(!diagnostic.message.contains(esc))
        #expect(!diagnostic.message.contains("]8;;"))
        #expect(!diagnostic.message.contains("https://"))
    }

    @Test("A BEL-terminated OSC 8 hyperlink is removed too")
    func stripsBellTerminatedHyperlinkEscapes() throws {
        let esc = "\u{1B}"
        let bel = "\u{07}"
        let output = "/path/to/Warns.swift:6:9: warning: result of call to 'loud()' is unused "
            + "[#\(esc)]8;;https://docs.swift.org/compiler/documentation/diagnostics/no-usage\(bel)NoUsage\(esc)]8;;\(bel)]"

        let diagnostic = try #require(BuildChecker.parseBuildOutput(output).first)

        #expect(diagnostic.message == "result of call to 'loud()' is unused [#NoUsage]")
    }

    // MARK: - Recorded Diagnostics

    private static func unusedResultWarning() -> Diagnostic {
        Diagnostic(
            severity: .warning,
            message: "result of call to 'loud()' is unused [#NoUsage]",
            filePath: "/path/to/Warns.swift",
            lineNumber: 6,
            columnNumber: 9,
            ruleId: "swift-compiler"
        )
    }

    private static func recorded(_ diagnostics: [Diagnostic], compiled: Int, read: Int) -> RecordedDiagnostics {
        RecordedDiagnostics(
            diagnostics: diagnostics,
            coverage: RecordedDiagnostics.Coverage(
                mapCount: 1, unitCount: compiled + read, compiledByThisRun: compiled, readFromRecord: read)
        )
    }

    @Test("The same warning in the transcript and the record is one diagnostic")
    func transcriptAndRecordAreMergedOnce() {
        let output = "/path/to/Warns.swift:6:9: warning: result of call to 'loud()' is unused [#NoUsage]"

        let result = BuildChecker.createResult(
            output: output,
            exitCode: 0,
            duration: .seconds(1),
            recorded: Self.recorded([Self.unusedResultWarning()], compiled: 1, read: 0)
        )

        #expect(result.status == .warning)
        #expect(result.diagnostics.filter { $0.severity == .warning } == [Self.unusedResultWarning()])
    }

    @Test("A warning the transcript prints twice is one diagnostic")
    func transcriptDuplicatesAreMergedOnce() {
        let line = "/path/to/Decl.swift:7:23: warning: 'Old' is deprecated: use something else [#DeprecatedDeclaration]"

        let result = BuildChecker.createResult(output: line + "\n" + line, exitCode: 0, duration: .seconds(1))

        #expect(result.status == .warning)
        #expect(result.diagnostics.filter { $0.severity == .warning }.count == 1)
    }

    @Test("A warning only the record holds makes the result a warning")
    func recordedOnlyWarningIsReported() {
        let result = BuildChecker.createResult(
            output: "Build complete! (0.41s)",
            exitCode: 0,
            duration: .seconds(1),
            recorded: Self.recorded([Self.unusedResultWarning()], compiled: 0, read: 1)
        )

        #expect(result.status == .warning)
        #expect(result.diagnostics.filter { $0.severity == .warning } == [Self.unusedResultWarning()])
        #expect(result.diagnostics.last?.ruleId == "build.diagnostic-coverage")
    }

    @Test("Unverified units make a clean build a warning, never a pass")
    func unverifiedUnitsAreAWarning() {
        let recorded = RecordedDiagnostics(
            diagnostics: [],
            coverage: RecordedDiagnostics.Coverage(
                mapCount: 1, unitCount: 2, compiledByThisRun: 0, readFromRecord: 1,
                unverified: ["Sources/Fixture/Warns.swift"])
        )

        let result = BuildChecker.createResult(
            output: "Build complete! (0.41s)", exitCode: 0, duration: .seconds(1), recorded: recorded)

        #expect(result.status == .warning)
        #expect(result.diagnostics.contains { $0.ruleId == "build.warnings-unverified" && $0.severity == .warning })
    }

    @Test("A failed build ignores the record: the transcript has the errors")
    func failedBuildIgnoresTheRecord() {
        let result = BuildChecker.createResult(
            output: "/path/to/Clean.swift:2:37: error: cannot convert value of type 'String' to specified type 'Int'",
            exitCode: 1,
            duration: .seconds(1),
            recorded: Self.recorded([Self.unusedResultWarning()], compiled: 0, read: 1)
        )

        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.severity) == [.error])
    }

    // MARK: - Result Cache

    @Test("build declares no cache inputs: the build system is the cache")
    func buildIsNotResultCached() {
        #expect(BuildChecker().cacheInputs(configuration: Configuration()) == nil)
    }
}
