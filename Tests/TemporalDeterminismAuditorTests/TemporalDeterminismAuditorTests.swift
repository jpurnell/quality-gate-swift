import Foundation
import Testing
@testable import TemporalDeterminismAuditor
@testable import QualityGateCore

// The rule suites (17 tests) moved to swift-vigil with the engine
// (Phase 4 extraction). What remains here is the gate adapter's own
// contract: identity, config plumbing, and verdict mapping.

@Suite("TemporalDeterminismAuditor: gate adapter")
struct TemporalDeterminismAuditorTests {

    @Test("Checker identity properties")
    func identity() {
        let auditor = TemporalDeterminismAuditor()
        #expect(auditor.id == "temporal-determinism")
        #expect(auditor.name == "Temporal Determinism Auditor")
    }

    @Test("A finding maps to a .warning verdict with the engine's diagnostic")
    func findingMapsToWarning() async throws {
        let code = """
        actor SimulationDevice {
            func next() -> Sample {
                Sample(timestamp: ContinuousClock.now)
            }
        }
        """
        let result = try await TemporalDeterminismAuditor().auditSource(
            code, fileName: "Sources/SimulationDevice.swift",
            configuration: Configuration())
        #expect(result.status == .warning)
        #expect(result.diagnostics.contains { $0.ruleId == "temporal-simulated-wall-clock" })
    }

    @Test("Clean source maps to .passed")
    func cleanMapsToPassed() async throws {
        let code = """
        struct Plain {
            func add(_ a: Int, _ b: Int) -> Int { a + b }
        }
        """
        let result = try await TemporalDeterminismAuditor().auditSource(
            code, fileName: "Sources/Plain.swift", configuration: Configuration())
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Gate configuration reaches the engine (exempt type is honored)")
    func configPlumbing() async throws {
        let code = """
        actor SimulationDevice {
            func next() -> Sample {
                Sample(timestamp: ContinuousClock.now)
            }
        }
        """
        var configuration = Configuration()
        configuration.temporalDeterminism = TemporalDeterminismConfig(
            exemptTypes: ["SimulationDevice"])
        let result = try await TemporalDeterminismAuditor().auditSource(
            code, fileName: "Sources/SimulationDevice.swift", configuration: configuration)
        #expect(result.status == .passed)
    }
}
