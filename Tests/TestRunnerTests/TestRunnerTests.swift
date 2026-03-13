import Foundation
import Testing
@testable import TestRunner
@testable import QualityGateCore

/// Tests for TestRunner.
///
/// TestRunner executes `swift test` and parses the output to extract
/// test failures and convert them to structured diagnostics.
@Suite("TestRunner Tests")
struct TestRunnerTests {

    // MARK: - Identity Tests

    @Test("TestRunner has correct id and name")
    func checkerIdentity() {
        let runner = TestRunner()
        #expect(runner.id == "test")
        #expect(runner.name == "Test Runner")
    }

    // MARK: - Swift Testing Output Parsing

    @Test("Parses Swift Testing failure")
    func parsesSwiftTestingFailure() {
        let output = """
        Test "My test" recorded an issue at MyTests.swift:42:9: Expectation failed: (actual → 5) == 10
        """

        let diagnostics = TestRunner.parseTestOutput(output)

        #expect(diagnostics.count == 1)
        let diagnostic = diagnostics.first!
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.file?.contains("MyTests.swift") == true)
        #expect(diagnostic.line == 42)
        #expect(diagnostic.message.contains("Expectation failed"))
    }

    @Test("Parses multiple Swift Testing failures")
    func parsesMultipleSwiftTestingFailures() {
        let output = """
        Test "First test" recorded an issue at FirstTests.swift:10:5: first failure
        Test "Second test" recorded an issue at SecondTests.swift:20:8: second failure
        Test "Third test" recorded an issue at ThirdTests.swift:30:12: third failure
        """

        let diagnostics = TestRunner.parseTestOutput(output)

        #expect(diagnostics.count == 3)
    }

    @Test("Parses Swift Testing test passed output")
    func parsesSwiftTestingPassed() {
        let output = """
        Test run started.
        Suite "MyTests" started.
        Test "My test" started.
        Test "My test" passed after 0.001 seconds.
        Suite "MyTests" passed after 0.002 seconds.
        Test run with 1 test passed.
        """

        let diagnostics = TestRunner.parseTestOutput(output)

        #expect(diagnostics.isEmpty)
    }

    // MARK: - XCTest Output Parsing

    @Test("Parses XCTest failure format")
    func parsesXCTestFailure() {
        let output = """
        /path/to/MyTests.swift:42: error: -[MyTests testSomething] : XCTAssertEqual failed: ("5") is not equal to ("10")
        """

        let diagnostics = TestRunner.parseTestOutput(output)

        #expect(diagnostics.count == 1)
        let diagnostic = diagnostics.first!
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.file == "/path/to/MyTests.swift")
        #expect(diagnostic.line == 42)
        #expect(diagnostic.message.contains("XCTAssertEqual failed"))
    }

    @Test("Parses XCTest fatal error")
    func parsesXCTestFatalError() {
        let output = """
        /path/to/MyTests.swift:25: error: -[MyTests testCrash] : failed: caught error: MyError
        """

        let diagnostics = TestRunner.parseTestOutput(output)

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .error)
    }

    // MARK: - Edge Cases

    @Test("Handles empty output")
    func handlesEmptyOutput() {
        let diagnostics = TestRunner.parseTestOutput("")
        #expect(diagnostics.isEmpty)
    }

    @Test("Handles build-only output")
    func handlesBuildOutput() {
        let output = """
        Building for debugging...
        [1/10] Compiling Module Source.swift
        Build complete!
        """

        let diagnostics = TestRunner.parseTestOutput(output)
        #expect(diagnostics.isEmpty)
    }

    @Test("Ignores compilation progress lines")
    func ignoresCompilationProgress() {
        let output = """
        [1/50] Compiling MyModule file1.swift
        [2/50] Compiling MyModule file2.swift
        Test "Failing test" recorded an issue at Tests.swift:10:5: failed
        [3/50] Linking
        """

        let diagnostics = TestRunner.parseTestOutput(output)

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.contains("failed") == true)
    }

    @Test("Parses paths with spaces")
    func parsesPathsWithSpaces() {
        let output = """
        /Users/name/My Project/Tests/MyTests.swift:42: error: -[MyTests test] : failed
        """

        let diagnostics = TestRunner.parseTestOutput(output)

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.file == "/Users/name/My Project/Tests/MyTests.swift")
    }

    // MARK: - Result Generation

    @Test("Returns passed status for all tests passing")
    func passedForAllTestsPassing() {
        let output = """
        Test run with 10 tests passed.
        """

        let result = TestRunner.createResult(
            output: output,
            exitCode: 0,
            duration: .seconds(5)
        )

        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Returns failed status for test failures")
    func failedForTestFailures() {
        let output = """
        Test "Failing test" recorded an issue at Tests.swift:10:5: failed
        Test run with 10 tests failed.
        """

        let result = TestRunner.createResult(
            output: output,
            exitCode: 1,
            duration: .seconds(5)
        )

        #expect(result.status == .failed)
        #expect(result.diagnostics.count >= 1)
    }

    @Test("Returns failed status for non-zero exit code even without parsed failures")
    func failedForNonZeroExitCode() {
        // Sometimes tests crash without clear output
        let output = """
        Test crashed unexpectedly
        """

        let result = TestRunner.createResult(
            output: output,
            exitCode: 1,
            duration: .seconds(1)
        )

        #expect(result.status == .failed)
    }

    @Test("Result includes checkerId")
    func resultIncludesCheckerId() {
        let result = TestRunner.createResult(
            output: "",
            exitCode: 0,
            duration: .seconds(1)
        )

        #expect(result.checkerId == "test")
    }

    @Test("Result includes duration")
    func resultIncludesDuration() {
        let result = TestRunner.createResult(
            output: "",
            exitCode: 0,
            duration: .seconds(10)
        )

        #expect(result.duration >= .seconds(0))
    }

    // MARK: - Configuration Tests

    @Test("Uses parallel workers from configuration")
    func usesParallelWorkers() {
        let config = Configuration(parallelWorkers: 4)
        let runner = TestRunner()

        let args = runner.testArguments(for: config)

        #expect(args.contains("--parallel"))
    }

    @Test("Applies test filter when specified")
    func appliesTestFilter() {
        let config = Configuration(testFilter: "MyTests")
        let runner = TestRunner()

        let args = runner.testArguments(for: config)

        #expect(args.contains("--filter"))
        #expect(args.contains("MyTests"))
    }

    @Test("Uses default workers when not specified")
    func usesDefaultWorkers() {
        let config = Configuration()
        let runner = TestRunner()

        let args = runner.testArguments(for: config)

        // Should still enable parallel by default
        #expect(args.contains("--parallel"))
    }

    // MARK: - Test Summary Parsing

    @Test("Extracts test count from summary")
    func extractsTestCount() {
        let output = """
        Test run with 42 tests in 5 suites passed after 1.5 seconds.
        """

        let summary = TestRunner.parseTestSummary(output)

        #expect(summary?.totalTests == 42)
        #expect(summary?.failedTests == 0)
    }

    @Test("Extracts failed test count from summary")
    func extractsFailedTestCount() {
        let output = """
        Test run with 42 tests failed after 1.5 seconds with 3 issues.
        """

        let summary = TestRunner.parseTestSummary(output)

        #expect(summary?.totalTests == 42)
        #expect(summary?.failedTests == 3)
    }

    @Test("Returns nil for no summary")
    func returnsNilForNoSummary() {
        let output = """
        Building...
        Compiling...
        """

        let summary = TestRunner.parseTestSummary(output)

        #expect(summary == nil)
    }
}
