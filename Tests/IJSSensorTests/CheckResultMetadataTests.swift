import Testing
import Foundation
@testable import IJSSensor
import QualityGateTypes

@Suite("EthicalFlag")
struct EthicalFlagTests {

    @Test("All five cases exist with correct raw values")
    func rawValues() {
        #expect(EthicalFlag.unauthorizedDataCollection.rawValue == "unauthorizedDataCollection")
        #expect(EthicalFlag.manipulativeUX.rawValue == "manipulativeUX")
        #expect(EthicalFlag.missingConsentGuard.rawValue == "missingConsentGuard")
        #expect(EthicalFlag.automatedDecisionRequiringHumanReview.rawValue == "automatedDecisionRequiringHumanReview")
        #expect(EthicalFlag.surveillanceFeature.rawValue == "surveillanceFeature")
    }

    @Test("Codable round-trip for each case")
    func codableRoundTrip() throws {
        let allCases: [EthicalFlag] = [
            .unauthorizedDataCollection, .manipulativeUX, .missingConsentGuard,
            .automatedDecisionRequiringHumanReview, .surveillanceFeature,
        ]
        for flag in allCases {
            let data = try JSONEncoder().encode(flag)
            let decoded = try JSONDecoder().decode(EthicalFlag.self, from: data)
            #expect(decoded == flag)
        }
    }
}

@Suite("Environment")
struct EnvironmentTests {

    @Test("Both cases with raw string values")
    func rawValues() {
        #expect(Environment.local.rawValue == "local")
        #expect(Environment.ci.rawValue == "ci")
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        for env in [Environment.local, .ci] {
            let data = try JSONEncoder().encode(env)
            let decoded = try JSONDecoder().decode(Environment.self, from: data)
            #expect(decoded == env)
        }
    }
}

@Suite("OverrideRecord")
struct OverrideRecordTests {

    static let sampleDiagnosticOverride = DiagnosticOverride(
        ruleId: "force-unwrap",
        justification: "SAFETY: Necessary for legacy C-API compatibility",
        filePath: "Sources/Interop/Bridge.swift",
        lineNumber: 42
    )

    static let sample = OverrideRecord(
        diagnosticOverride: sampleDiagnosticOverride,
        author: "j_doe_senior_dev",
        riskTier: .safety,
        authorityLevel: .decisionOwner
    )

    @Test("Golden path: all fields populated")
    func goldenPath() {
        let record = Self.sample
        #expect(record.diagnosticOverride.ruleId == "force-unwrap")
        #expect(record.diagnosticOverride.justification.contains("C-API"))
        #expect(record.author == "j_doe_senior_dev")
        #expect(record.riskTier == .safety)
        #expect(record.authorityLevel == .decisionOwner)
    }

    @Test("Codable round-trip with camelCase keys")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let decoded = try JSONDecoder().decode(OverrideRecord.self, from: data)
        #expect(decoded == Self.sample)

        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"diagnosticOverride\""))
        #expect(json.contains("\"ruleId\""))
        #expect(json.contains("\"riskTier\""))
        #expect(json.contains("\"authorityLevel\""))
    }
}

@Suite("CheckResult (shared type integration)")
struct CheckResultIntegrationTests {

    static let sampleDiagnostic = Diagnostic(
        severity: .error,
        message: "Division by zero protection missing",
        filePath: "Sources/Math/Division.swift",
        lineNumber: 42,
        ruleId: "safety.division-by-zero",
        suggestedFix: "Add zero check guard"
    )

    static let sample = CheckResult(
        checkerId: "SafetyAuditor",
        status: .failed,
        diagnostics: [sampleDiagnostic],
        duration: .seconds(2)
    )

    @Test("Shared CheckResult type integrates with IJS")
    func properties() {
        #expect(Self.sample.checkerId == "SafetyAuditor")
        #expect(Self.sample.status == .failed)
        #expect(Self.sample.diagnostics.count == 1)
        #expect(Self.sample.diagnostics[0].filePath == "Sources/Math/Division.swift")
        #expect(Self.sample.diagnostics[0].isFixable == true)
    }

    @Test("Codable round-trip with camelCase checkerId")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"checkerId\""))
        #expect(json.contains("\"filePath\""))
        #expect(json.contains("\"lineNumber\""))

        let decoded = try JSONDecoder().decode(CheckResult.self, from: data)
        #expect(decoded == Self.sample)
    }
}

@Suite("CheckResultMetadata")
struct CheckResultMetadataTests {

    static func makeSample(
        ethicalFlags: [EthicalFlag] = [],
        overrides: [OverrideRecord] = [],
        consistencyScore: Double? = nil
    ) -> CheckResultMetadata {
        CheckResultMetadata(
            projectID: "BusinessMath-Lib",
            timestamp: Date(timeIntervalSince1970: 1_777_536_311),
            environment: .ci,
            decisionOwner: "j_doe_senior_dev",
            results: [CheckResultIntegrationTests.sample],
            overrides: overrides,
            riskTier: .safety,
            ethicalFlags: ethicalFlags,
            consistencyScore: consistencyScore
        )
    }

    @Test("Golden path: full metadata with results and overrides")
    func goldenPath() {
        let meta = Self.makeSample(
            overrides: [OverrideRecordTests.sample],
            consistencyScore: 0.85
        )
        #expect(meta.projectID == "BusinessMath-Lib")
        #expect(meta.environment == .ci)
        #expect(meta.decisionOwner == "j_doe_senior_dev")
        #expect(meta.results.count == 1)
        #expect(meta.overrides.count == 1)
        #expect(meta.riskTier == .safety)
        #expect(abs((meta.consistencyScore ?? 0) - 0.85) < 1e-6)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let meta = Self.makeSample(
            ethicalFlags: [.manipulativeUX],
            overrides: [OverrideRecordTests.sample],
            consistencyScore: 0.92
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(meta)
        let decoded = try decoder.decode(CheckResultMetadata.self, from: data)
        #expect(decoded == meta)
    }

    @Test("camelCase JSON keys match MCP schema")
    func camelCaseKeys() throws {
        let meta = Self.makeSample(consistencyScore: 0.5)
        let data = try JSONEncoder().encode(meta)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"projectID\""))
        #expect(json.contains("\"decisionOwner\""))
        #expect(json.contains("\"riskTier\""))
        #expect(json.contains("\"ethicalFlags\""))
        #expect(json.contains("\"consistencyScore\""))
    }

    @Test("Empty overrides array")
    func emptyOverrides() throws {
        let meta = Self.makeSample(overrides: [])
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(CheckResultMetadata.self, from: data)
        #expect(decoded.overrides.isEmpty)
    }

    @Test("Empty ethical flags array")
    func emptyEthicalFlags() throws {
        let meta = Self.makeSample(ethicalFlags: [])
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(CheckResultMetadata.self, from: data)
        #expect(decoded.ethicalFlags.isEmpty)
    }

    @Test("consistencyScore nil encodes correctly")
    func nilConsistencyScore() throws {
        let meta = Self.makeSample(consistencyScore: nil)
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(CheckResultMetadata.self, from: data)
        #expect(decoded.consistencyScore == nil)
    }

    @Test("consistencyScore populated")
    func populatedConsistencyScore() throws {
        let meta = Self.makeSample(consistencyScore: 0.75)
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(CheckResultMetadata.self, from: data)
        #expect(abs((decoded.consistencyScore ?? 0) - 0.75) < 1e-6)
    }

    @Test("Multiple results with multiple diagnostics")
    func multipleResults() throws {
        let result2 = CheckResult(
            checkerId: "ConcurrencyAuditor",
            status: .failed,
            diagnostics: [
                Diagnostic(severity: .error, message: "msg1", filePath: "A.swift", lineNumber: 1, ruleId: "concurrency.1"),
                Diagnostic(severity: .warning, message: "msg2", filePath: "B.swift", lineNumber: 2, ruleId: "concurrency.2", suggestedFix: "Fix"),
            ],
            duration: .seconds(1)
        )
        let meta = CheckResultMetadata(
            projectID: "Test",
            timestamp: Date(timeIntervalSince1970: 0),
            environment: .local,
            decisionOwner: "tester",
            results: [CheckResultIntegrationTests.sample, result2],
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil
        )
        #expect(meta.results.count == 2)
        #expect(meta.results[1].diagnostics.count == 2)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        let decoded = try decoder.decode(CheckResultMetadata.self, from: data)
        #expect(decoded.results.count == 2)
    }

    @Test("Date encodes as ISO 8601")
    func dateEncoding() throws {
        let meta = Self.makeSample()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("2026-"))
    }
}
