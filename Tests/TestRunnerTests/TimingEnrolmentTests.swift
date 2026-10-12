import Foundation
import Testing
@testable import TestRunner
@testable import QualityGateCore

/// A `// TIMING:` on an assertion line enrols its test in stress runs.
///
/// `TemporalScan`'s documentation says so: the marker "exempts the assertion rule — and
/// enrolls the test in vigil's stress runs". The scanner behind stress mode read only the
/// comment *above the test function*, so the marker written where the temporal rule asks for
/// it — on the wall-clock assertion — silenced the warning and enrolled nothing. The tests
/// that most need provoking, HRVKit's teardown-liveness bounds among them, were never run.
@Suite("TestRunner: // TIMING: on an assertion enrols the test")
struct TimingEnrolmentTests {

    private func roster(_ source: String, marker: String = "// TIMING:") throws -> [String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("timing-enrol-\(UUID().uuidString)", isDirectory: true)
        let tests = root.appendingPathComponent("Tests/KitTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try source.write(to: tests.appendingPathComponent("KitTests.swift"), atomically: true, encoding: .utf8)
        return TestRunner.timingTests(projectRoot: root.path, marker: marker)
    }

    /// quality-gate-corpus-kit `Tests/CorpusKitTests/ProcessRunnerTests.swift:105-117`.
    @Test("The marker on the line above a Swift Testing assertion enrols the test")
    func lineAboveExpect() throws {
        let names = try roster(#"""
            import Testing
            struct ProcessRunnerTests {
                @Test func timesOutHangingChild() throws {
                    let started = Date()
                    let result = try ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 60"], timeout: 1)
                    let elapsed = Date().timeIntervalSince(started)

                    #expect(result.timedOut == true)
                    // TIMING: The bound under test is itself wall-clock; 20x the 1s timeout absorbs load.
                    #expect(elapsed < 20, "expected the timeout to bound the run, took \(elapsed)s")
                }
                @Test func untagged() {
                    #expect(1 + 1 == 2)
                }
            }
            """#)
        #expect(names == ["timesOutHangingChild"])
    }

    @Test("The marker trailing an assertion on its own line enrols the test")
    func trailingOnTheAssertionLine() throws {
        let names = try roster("""
            import XCTest
            final class TeardownTests: XCTestCase {
                func testStopCompletes() {
                    let elapsed = measure()
                    XCTAssertLessThan(elapsed, 2.0) // TIMING: intentional liveness bound
                }
            }
            """)
        #expect(names == ["testStopCompletes"])
    }

    @Test("The marker above the test function still enrols it, once")
    func functionLevelMarkerStillEnrols() throws {
        let names = try roster("""
            import Testing
            struct S {
                // TIMING: teardown liveness bound
                @Test func teardown() async {
                    // TIMING: and again on the assertion
                    #expect(elapsed < .seconds(2))
                }
                @Test func other() {}
            }
            """)
        #expect(names == ["teardown"])
    }

    // MARK: - Near misses: the marker somewhere that exempts nothing

    /// swift-vigil pins this shape as untagged (`TimingTestScannerTests.ignoresBodyTrailingComment`).
    @Test("The marker on a line that is not an assertion enrols nothing")
    func markerOnANonAssertionLine() throws {
        let names = try roster("""
            import Testing
            struct S {
                @Test func plain() {
                    let elapsed = measure()
                    _ = elapsed // TIMING: intentional load benchmark
                    consume(elapsed)
                    #expect(elapsed > 0)
                }
            }
            """)
        #expect(names == [])
    }

    @Test("The marker inside an assertion's string argument is not a comment")
    func markerInsideAStringLiteral() throws {
        let names = try roster("""
            import Testing
            struct S {
                @Test func plain() {
                    #expect(elapsed < 2, "see // TIMING: in the guide")
                }
            }
            """)
        #expect(names == [])
    }

    @Test("The marker on an assertion in a function that is not a test enrols nothing")
    func markerInAHelper() throws {
        let names = try roster("""
            import Testing
            func helper(elapsed: Double) {
                // TIMING: shared bound
                #expect(elapsed < 2)
            }
            """)
        #expect(names == [])
    }

    @Test("A configured marker is the one that is read")
    func configuredMarker() throws {
        let source = """
            import Testing
            struct S {
                @Test func bounded() {
                    // STRESS: reconnect budget
                    #expect(elapsed < 2)
                }
            }
            """
        #expect(try roster(source, marker: "// STRESS:") == ["bounded"])
        #expect(try roster(source) == [])
    }
}
