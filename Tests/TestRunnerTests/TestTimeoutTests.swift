import Foundation
import Testing
@testable import TestRunner
@testable import QualityGateCore

// A `swift test` that is cut off at the time limit has not passed. It was reported as
// "Ad-hoc code signing failed (tests passed)" — a warning — when three things lined up: the
// kernel's timeout exit code is non-zero like any failure, a bundle that finished before the
// cut-off had printed a "passed" summary, and the output contained the words "codesign
// failed". In this package those words are the name of a test. A non-strict hook then let
// the commit through on a run that never finished.

/// What `swift test` had printed when it was terminated: one bundle done, the rest not.
private let partialOutput = """
􀟈  Test "Passes on codesign failed variant" started.
􁁛  Test "Passes on codesign failed variant" passed after 0.001 seconds.
􁁛  Test run with 94 tests in 7 suites passed after 144.502 seconds.
􀟈  Test "A slow one" started.

process-kernel: `/usr/bin/swift` timed out after 600s and was terminated.
"""

@Suite("test: a run that was cut off")
struct TestTimeoutTests {

    @Test("A timed-out run fails, whatever had passed before the cut-off")
    func timedOutRunFails() {
        let result = TestRunner.createResult(output: partialOutput, exitCode: 124, duration: .seconds(600))
        #expect(result.status == .failed)
        let timeout = result.diagnostics.first { $0.ruleId == "test-timeout" }
        #expect(timeout?.severity == .error)
        #expect(timeout?.message.contains("600s") == true)
        #expect(!result.diagnostics.contains { $0.ruleId == "test-codesign" })
    }

    @Test("A timed-out run that printed nothing fails with the same finding")
    func silentTimeoutFails() {
        let output = "\nprocess-kernel: `/usr/bin/swift` timed out after 600s and was terminated."
        let result = TestRunner.createResult(output: output, exitCode: 124, duration: .seconds(600))
        #expect(result.status == .failed)
        #expect(result.diagnostics.map(\.ruleId) == ["test-timeout"])
    }

    @Test("The words in a test's name are not a signing error")
    func aTestNameIsNotASigningError() {
        let output = """
        􀟈  Test "Passes on codesign failed variant" started.
        􁁛  Test "Passes on codesign failed variant" passed after 0.001 seconds.
        􁁛  Test run with 1 test in 1 suite passed after 0.002 seconds.
        """
        // A non-zero exit with nothing to explain it is a failure. The only mention of
        // signing here is inside the quotation marks of a test's name.
        let result = TestRunner.createResult(output: output, exitCode: 1, duration: .seconds(3))
        #expect(result.status == .failed)
        #expect(!result.diagnostics.contains { $0.ruleId == "test-codesign" })
    }

    @Test("A real signing failure after every test passed is still a warning, not a failure")
    func realSigningFailureIsStillAWarning() {
        let output = """
        􁁛  Test run with 12 tests in 2 suites passed after 0.210 seconds.
        /path/to/.build/debug/ExamplePackageTests.xctest: internal error in Code Signing subsystem
        """
        let result = TestRunner.createResult(output: output, exitCode: 1, duration: .seconds(3))
        #expect(result.status == .passed)
        #expect(result.diagnostics.map(\.ruleId) == ["test-codesign"])
    }

    @Test("The codesign-failed spelling on a toolchain line is still recognised")
    func codesignFailedLineIsStillRecognised() {
        let output = """
        􁁛  Test run with 12 tests in 2 suites passed after 0.210 seconds.
        /path/to/.build/debug/ExamplePackageTests.xctest: codesign failed
        """
        let result = TestRunner.createResult(output: output, exitCode: 1, duration: .seconds(3))
        #expect(result.status == .passed)
        #expect(result.diagnostics.map(\.ruleId) == ["test-codesign"])
    }
}
