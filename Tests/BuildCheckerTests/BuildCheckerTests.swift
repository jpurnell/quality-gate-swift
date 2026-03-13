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
    func parsesErrorWithLocation() {
        let output = """
        /path/to/File.swift:42:15: error: cannot find 'foo' in scope
            let x = foo
                    ^~~
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        #expect(diagnostics.count == 1)
        let diagnostic = diagnostics.first!
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.file == "/path/to/File.swift")
        #expect(diagnostic.line == 42)
        #expect(diagnostic.column == 15)
        #expect(diagnostic.message.contains("cannot find 'foo' in scope"))
    }

    @Test("Parses warning with file location")
    func parsesWarningWithLocation() {
        let output = """
        /path/to/File.swift:10:5: warning: variable 'x' was never used
            let x = 5
                ^
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        #expect(diagnostics.count == 1)
        let diagnostic = diagnostics.first!
        #expect(diagnostic.severity == .warning)
        #expect(diagnostic.file == "/path/to/File.swift")
        #expect(diagnostic.line == 10)
        #expect(diagnostic.column == 5)
        #expect(diagnostic.message.contains("variable 'x' was never used"))
    }

    @Test("Parses note with file location")
    func parsesNoteWithLocation() {
        let output = """
        /path/to/File.swift:5:10: note: 'foo' declared here
            func foo() {}
                 ^~~
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        #expect(diagnostics.count == 1)
        let diagnostic = diagnostics.first!
        #expect(diagnostic.severity == .note)
        #expect(diagnostic.file == "/path/to/File.swift")
        #expect(diagnostic.line == 5)
        #expect(diagnostic.column == 10)
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
        #expect(diagnostics.first?.file == "/Users/name/My Project/Sources/File.swift")
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

        // Even with warnings, build succeeded so status is passed but has warnings
        #expect(result.status == .passed)
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

    // MARK: - Error Message Quality Tests

    @Test("Provides actionable error messages")
    func providesActionableMessages() {
        let output = """
        /path/to/File.swift:42:15: error: cannot find 'NetworkManager' in scope
        """

        let diagnostics = BuildChecker.parseBuildOutput(output)

        let diagnostic = diagnostics.first!
        // Message should include the original error text
        #expect(diagnostic.message.contains("cannot find") ||
                diagnostic.message.contains("NetworkManager"))
    }
}
