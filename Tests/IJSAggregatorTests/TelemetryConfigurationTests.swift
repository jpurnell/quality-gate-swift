import Testing
import Foundation
@testable import IJSAggregator
import IJSSensor

@Suite("TelemetryConfiguration")
struct TelemetryConfigurationTests {

    static let sample = TelemetryConfiguration(
        projectID: "quality-gate-swift",
        corpusPath: "/Users/test/corpus",
        decisionOwner: "jpurnell",
        defaultRiskTier: .operational,
        environment: .ci
    )

    @Test("Golden path: all fields populated")
    func goldenPath() {
        let config = Self.sample
        #expect(config.projectID == "quality-gate-swift")
        #expect(config.corpusPath == "/Users/test/corpus")
        #expect(config.decisionOwner == "jpurnell")
        #expect(config.defaultRiskTier == .operational)
        #expect(config.environment == .ci)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let decoded = try JSONDecoder().decode(TelemetryConfiguration.self, from: data)
        #expect(decoded == Self.sample)
    }

    @Test("camelCase JSON keys")
    func camelCaseKeys() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"projectID\""))
        #expect(json.contains("\"corpusPath\""))
        #expect(json.contains("\"decisionOwner\""))
        #expect(json.contains("\"defaultRiskTier\""))
        #expect(json.contains("\"environment\""))
    }

    @Test("Nil environment encodes and decodes correctly")
    func nilEnvironment() throws {
        let config = TelemetryConfiguration(
            projectID: "test",
            corpusPath: "/tmp",
            decisionOwner: "tester",
            defaultRiskTier: .informational,
            environment: nil
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TelemetryConfiguration.self, from: data)
        #expect(decoded.environment == nil)
    }

    @Test("Equatable: matching configs are equal")
    func equatable() {
        let a = Self.sample
        let b = TelemetryConfiguration(
            projectID: "quality-gate-swift",
            corpusPath: "/Users/test/corpus",
            decisionOwner: "jpurnell",
            defaultRiskTier: .operational,
            environment: .ci
        )
        #expect(a == b)
    }

    @Test("Equatable: different projectID produces inequality")
    func notEqual() {
        let other = TelemetryConfiguration(
            projectID: "other-project",
            corpusPath: "/Users/test/corpus",
            decisionOwner: "jpurnell",
            defaultRiskTier: .operational,
            environment: .ci
        )
        #expect(Self.sample != other)
    }

    @Test("Load from valid YAML with ijs section")
    func loadFromYAML() throws {
        let yaml = """
        parallelWorkers: 8
        ijs:
          projectID: "business-math"
          corpusPath: "/tmp/corpus"
          decisionOwner: "jpurnell"
          defaultRiskTier: 2
          environment: "ci"
        """
        let tmpDir = FileManager.default.temporaryDirectory
        let yamlURL = tmpDir.appendingPathComponent("test-\(UUID().uuidString).quality-gate.yml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: yamlURL) }

        let config = try TelemetryConfiguration.load(from: yamlURL)
        #expect(config.projectID == "business-math")
        #expect(config.corpusPath == "/tmp/corpus")
        #expect(config.decisionOwner == "jpurnell")
        #expect(config.defaultRiskTier == .operational)
        #expect(config.environment == .ci)
    }

    @Test("Load from YAML with nil environment")
    func loadFromYAMLNilEnvironment() throws {
        let yaml = """
        ijs:
          projectID: "test"
          corpusPath: "/tmp/corpus"
          decisionOwner: "tester"
          defaultRiskTier: 3
        """
        let tmpDir = FileManager.default.temporaryDirectory
        let yamlURL = tmpDir.appendingPathComponent("test-\(UUID().uuidString).quality-gate.yml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: yamlURL) }

        let config = try TelemetryConfiguration.load(from: yamlURL)
        #expect(config.environment == nil)
        #expect(config.defaultRiskTier == .safety)
    }

    @Test("Load from YAML without ijs section throws configurationError")
    func loadFromYAMLMissingSection() throws {
        let yaml = """
        parallelWorkers: 8
        excludePatterns:
          - "*.generated"
        """
        let tmpDir = FileManager.default.temporaryDirectory
        let yamlURL = tmpDir.appendingPathComponent("test-\(UUID().uuidString).quality-gate.yml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: yamlURL) }

        #expect(throws: IJSError.self) {
            try TelemetryConfiguration.load(from: yamlURL)
        }
    }

    @Test("Load from nonexistent file throws configurationError")
    func loadFromMissingFile() {
        let bogusURL = URL(fileURLWithPath: "/nonexistent/path/.quality-gate.yml")
        #expect(throws: IJSError.self) {
            try TelemetryConfiguration.load(from: bogusURL)
        }
    }

    @Test("Sendable conformance")
    func sendable() {
        let config: any Sendable = Self.sample
        #expect(config is TelemetryConfiguration)
    }

    @Test("Default scorerWeights and empty exemptions")
    func defaultScorerWeightsAndExemptions() {
        let config = TelemetryConfiguration(
            projectID: "test",
            corpusPath: "/tmp",
            decisionOwner: "tester",
            defaultRiskTier: .operational,
            environment: nil
        )
        #expect(config.scorerWeights == ScorerWeights.defaults)
        #expect(config.consistencyExemptions.isEmpty)
    }

    @Test("Custom scorerWeights stored correctly")
    func customScorerWeights() {
        let weights = ScorerWeights(clusterMatch: 0.20, anomalyPattern: 0.15, unaddressedPolicy: 0.10, recurrenceBonus: 0.05)
        let config = TelemetryConfiguration(
            projectID: "test",
            corpusPath: "/tmp",
            decisionOwner: "tester",
            defaultRiskTier: .operational,
            environment: nil,
            scorerWeights: weights,
            consistencyExemptions: []
        )
        #expect(config.scorerWeights == weights)
    }

    @Test("Load from YAML with scorerWeights section")
    func loadScorerWeightsFromYAML() throws {
        let yaml = """
        ijs:
          projectID: "test"
          corpusPath: "/tmp"
          decisionOwner: "tester"
          defaultRiskTier: 2
          scorerWeights:
            clusterMatch: 0.20
            anomalyPattern: 0.15
            unaddressedPolicy: 0.10
            recurrenceBonus: 0.05
        """
        let tmpDir = FileManager.default.temporaryDirectory
        let yamlURL = tmpDir.appendingPathComponent("test-\(UUID().uuidString).quality-gate.yml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: yamlURL) }

        let config = try TelemetryConfiguration.load(from: yamlURL)
        #expect(abs(config.scorerWeights.clusterMatch - 0.20) < 1e-6)
        #expect(abs(config.scorerWeights.anomalyPattern - 0.15) < 1e-6)
        #expect(abs(config.scorerWeights.unaddressedPolicy - 0.10) < 1e-6)
        #expect(abs(config.scorerWeights.recurrenceBonus - 0.05) < 1e-6)
    }

    @Test("Load from YAML without scorerWeights uses defaults")
    func loadDefaultScorerWeightsFromYAML() throws {
        let yaml = """
        ijs:
          projectID: "test"
          corpusPath: "/tmp"
          decisionOwner: "tester"
          defaultRiskTier: 2
        """
        let tmpDir = FileManager.default.temporaryDirectory
        let yamlURL = tmpDir.appendingPathComponent("test-\(UUID().uuidString).quality-gate.yml")
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: yamlURL) }

        let config = try TelemetryConfiguration.load(from: yamlURL)
        #expect(config.scorerWeights == ScorerWeights.defaults)
    }

    @Test("All RiskTier raw values map correctly from YAML integers")
    func riskTierMapping() throws {
        for (raw, expected) in [(1, RiskTier.informational), (2, .operational), (3, .safety), (4, .critical)] {
            let yaml = """
            ijs:
              projectID: "test"
              corpusPath: "/tmp"
              decisionOwner: "tester"
              defaultRiskTier: \(raw)
            """
            let tmpDir = FileManager.default.temporaryDirectory
            let yamlURL = tmpDir.appendingPathComponent("test-\(UUID().uuidString).quality-gate.yml")
            try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: yamlURL) }

            let config = try TelemetryConfiguration.load(from: yamlURL)
            #expect(config.defaultRiskTier == expected)
        }
    }
}
