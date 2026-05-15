import Testing
import Foundation
@testable import IJSAggregator
import IJSSensor

@Suite("IJSError")
struct IJSErrorTests {

    @Test("unjustifiedOverride carries diagnostic description")
    func unjustifiedOverride() {
        let error = IJSError.unjustifiedOverride(diagnostic: "force-unwrap at Line 42")
        if case .unjustifiedOverride(let desc) = error {
            #expect(desc == "force-unwrap at Line 42")
        } else {
            Issue.record("Wrong case")
        }
    }

    @Test("riskTierMismatch carries required and actual authority")
    func riskTierMismatch() {
        let error = IJSError.riskTierMismatch(required: .decisionOwner, actual: .practitioner)
        if case .riskTierMismatch(let required, let actual) = error {
            #expect(required == .decisionOwner)
            #expect(actual == .practitioner)
        } else {
            Issue.record("Wrong case")
        }
    }

    @Test("telemetryWriteFailed carries reason")
    func telemetryWriteFailed() {
        let error = IJSError.telemetryWriteFailed(reason: "Permission denied")
        if case .telemetryWriteFailed(let reason) = error {
            #expect(reason == "Permission denied")
        } else {
            Issue.record("Wrong case")
        }
    }

    @Test("telemetryReadFailed carries reason")
    func telemetryReadFailed() {
        let error = IJSError.telemetryReadFailed(reason: "Corrupt JSON")
        if case .telemetryReadFailed(let reason) = error {
            #expect(reason == "Corrupt JSON")
        } else {
            Issue.record("Wrong case")
        }
    }

    @Test("configurationError carries reason")
    func configurationError() {
        let error = IJSError.configurationError(reason: "Missing ijs section")
        if case .configurationError(let reason) = error {
            #expect(reason == "Missing ijs section")
        } else {
            Issue.record("Wrong case")
        }
    }

    @Test("Equatable: matching cases are equal")
    func equatable() {
        let a = IJSError.telemetryWriteFailed(reason: "disk full")
        let b = IJSError.telemetryWriteFailed(reason: "disk full")
        #expect(a == b)
    }

    @Test("Equatable: different cases are not equal")
    func notEqual() {
        let a = IJSError.telemetryWriteFailed(reason: "disk full")
        let b = IJSError.telemetryReadFailed(reason: "disk full")
        #expect(a != b)
    }

    @Test("Equatable: same case different payloads are not equal")
    func differentPayloads() {
        let a = IJSError.telemetryWriteFailed(reason: "disk full")
        let b = IJSError.telemetryWriteFailed(reason: "permission denied")
        #expect(a != b)
    }

    @Test("institutionalInconsistency carries pattern")
    func institutionalInconsistency() {
        let error = IJSError.institutionalInconsistency(pattern: "concurrency.unchecked-sendable recurs 3 weeks")
        if case .institutionalInconsistency(let pattern) = error {
            #expect(pattern == "concurrency.unchecked-sendable recurs 3 weeks")
        } else {
            Issue.record("Wrong case")
        }
    }

    @Test("pulseGenerationFailed carries reason")
    func pulseGenerationFailed() {
        let error = IJSError.pulseGenerationFailed(reason: "No metadata in window")
        if case .pulseGenerationFailed(let reason) = error {
            #expect(reason == "No metadata in window")
        } else {
            Issue.record("Wrong case")
        }
    }

    @Test("LocalizedError provides non-empty descriptions")
    func localizedDescriptions() {
        let errors: [IJSError] = [
            .unjustifiedOverride(diagnostic: "test"),
            .riskTierMismatch(required: .executive, actual: .peer),
            .telemetryWriteFailed(reason: "test"),
            .telemetryReadFailed(reason: "test"),
            .configurationError(reason: "test"),
            .institutionalInconsistency(pattern: "test"),
            .pulseGenerationFailed(reason: "test"),
        ]
        for error in errors {
            #expect(error.localizedDescription.isEmpty == false)
        }
    }

    @Test("Error conforms to Sendable")
    func sendable() {
        let error: any Sendable = IJSError.telemetryWriteFailed(reason: "test")
        #expect(error is IJSError)
    }
}
