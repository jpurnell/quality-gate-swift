import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import TemporalDeterminismAuditor
@testable import QualityGateCore

// MARK: - Test Helpers

/// Parses a source string and runs the temporal visitor, returning diagnostics.
private func diagnose(
    _ source: String,
    filePath: String = "Sources/Thing.swift",
    config: TemporalDeterminismConfig = .default
) -> [Diagnostic] {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: filePath, tree: tree)
    let visitor = TemporalVisitor(
        filePath: filePath,
        converter: converter,
        sourceLines: source.components(separatedBy: "\n"),
        config: config
    )
    visitor.walk(tree)
    return visitor.diagnostics
}

/// Parses a source string and returns the recorded overrides (exemptions).
private func overridesFor(
    _ source: String,
    filePath: String = "Tests/ThingTests.swift",
    config: TemporalDeterminismConfig = .default
) -> [DiagnosticOverride] {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: filePath, tree: tree)
    let visitor = TemporalVisitor(
        filePath: filePath,
        converter: converter,
        sourceLines: source.components(separatedBy: "\n"),
        config: config
    )
    visitor.walk(tree)
    return visitor.overrides
}

private let simRule = "temporal-simulated-wall-clock"
private let assertRule = "temporal-wall-clock-assertion"

// MARK: - Identity

@Suite("TemporalDeterminismAuditor: Identity")
struct IdentityTests {
    @Test("Checker identity properties")
    func identity() {
        let auditor = TemporalDeterminismAuditor()
        #expect(auditor.id == "temporal-determinism")
        #expect(auditor.name == "Temporal Determinism Auditor")
    }
}

// MARK: - Rule 1: simulated wall-clock timestamps

@Suite("TemporalDeterminismAuditor: temporal-simulated-wall-clock")
struct SimulatedWallClockTests {
    @Test("Flags the exact SimulationDevice regression shape")
    func flagsSimulationDeviceTimestamp() {
        let code = """
        actor SimulationDevice {
            func generateNextSample(at elapsedSeconds: Double) -> BioSample {
                return BioSample(rrInterval: rr, timestamp: ContinuousClock.now)
            }
        }
        """
        #expect(diagnose(code).contains { $0.ruleId == simRule })
    }

    @Test("Flags Date() stamped as timestamp in a Mock type")
    func flagsMockDate() {
        let code = """
        struct MockClock {
            func emit() -> Event { Event(at: Date()) }
        }
        """
        #expect(diagnose(code).contains { $0.ruleId == simRule })
    }

    @Test("Flags property assignment of wall-clock time in a Synthetic type")
    func flagsSyntheticAssignment() {
        let code = """
        final class SyntheticSource {
            var timestamp = ContinuousClock.now
            func tick() { self.timestamp = ContinuousClock.now }
        }
        """
        #expect(diagnose(code).contains { $0.ruleId == simRule })
    }

    @Test("Flags a type that conforms to a simulation-named protocol")
    func flagsSimulationConformance() {
        let code = """
        struct FastDevice: SimulatedDevice {
            func next() -> Sample { Sample(time: ContinuousClock.now) }
        }
        """
        #expect(diagnose(code).contains { $0.ruleId == simRule })
    }

    // MARK: Must NOT flag

    @Test("Does not flag a real (non-simulated) device")
    func ignoresRealDevice() {
        let code = """
        actor PolarDevice {
            func read() -> BioSample { BioSample(rrInterval: rr, timestamp: ContinuousClock.now) }
        }
        """
        #expect(diagnose(code).isEmpty)
    }

    @Test("Does not flag logical-origin timestamps in a simulation type")
    func ignoresLogicalOrigin() {
        let code = """
        actor SimulationDevice {
            func sample(origin: ContinuousClock.Instant, elapsed: Double) -> BioSample {
                let timestamp = origin.advanced(by: .milliseconds(Int(elapsed * 1000)))
                return BioSample(rrInterval: rr, timestamp: timestamp)
            }
        }
        """
        #expect(diagnose(code).isEmpty)
    }

    @Test("Respects // temporal:exempt")
    func respectsExemptComment() {
        let code = """
        actor SimulationDevice {
            func s() -> BioSample {
                BioSample(rrInterval: rr, timestamp: ContinuousClock.now) // temporal:exempt
            }
        }
        """
        #expect(diagnose(code).isEmpty)
        #expect(overridesFor(code, filePath: "Sources/S.swift").contains { $0.ruleId == simRule })
    }

    @Test("Respects config.exemptTypes")
    func respectsExemptTypes() {
        let code = """
        actor SimulationDevice {
            func s() -> BioSample { BioSample(rrInterval: rr, timestamp: ContinuousClock.now) }
        }
        """
        let cfg = TemporalDeterminismConfig(exemptTypes: ["SimulationDevice"])
        #expect(diagnose(code, config: cfg).isEmpty)
    }
}

// MARK: - Rule 2: wall-clock timing assertions

@Suite("TemporalDeterminismAuditor: temporal-wall-clock-assertion")
struct WallClockAssertionTests {
    private let testPath = "Tests/PerfTests.swift"

    @Test("Flags #expect on an elapsed-time variable")
    func flagsElapsedVar() {
        let code = """
        @Test func perf() {
            let start = ContinuousClock.now
            doWork()
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(1))
        }
        """
        #expect(diagnose(code, filePath: testPath).contains { $0.ruleId == assertRule })
    }

    @Test("Flags inline Date().timeIntervalSince threshold")
    func flagsInlineTimeInterval() {
        let code = """
        func testSpeed() {
            let start = Date()
            run()
            #expect(Date().timeIntervalSince(start) < 0.5)
        }
        """
        #expect(diagnose(code, filePath: testPath).contains { $0.ruleId == assertRule })
    }

    @Test("Flags XCTAssertLessThan on elapsed duration")
    func flagsXCTAssertLessThan() {
        let code = """
        func testBudget() {
            let start = ContinuousClock.now
            work()
            let elapsed = ContinuousClock.now - start
            XCTAssertLessThan(elapsed, .seconds(2))
        }
        """
        #expect(diagnose(code, filePath: testPath).contains { $0.ruleId == assertRule })
    }

    // MARK: Must NOT flag

    @Test("Does not flag assertions on logical timestamp ordering")
    func ignoresLogicalTimestampAssertion() {
        let code = """
        @Test func monotonic() {
            for i in 1..<samples.count {
                #expect(samples[i].timestamp > samples[i - 1].timestamp)
            }
        }
        """
        #expect(diagnose(code, filePath: testPath).isEmpty)
    }

    @Test("Does not flag a plain value assertion")
    func ignoresPlainAssertion() {
        let code = """
        @Test func math() {
            #expect(result == 42)
            #expect(count < 100)
        }
        """
        #expect(diagnose(code, filePath: testPath).isEmpty)
    }

    @Test("Respects // TIMING: on the assertion line")
    func respectsTimingComment() {
        let code = """
        func testPerf() {
            let start = ContinuousClock.now
            work()
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(1)) // TIMING: intentional load benchmark
        }
        """
        #expect(diagnose(code, filePath: testPath).isEmpty)
        #expect(overridesFor(code, filePath: testPath).contains { $0.ruleId == assertRule })
    }
}
