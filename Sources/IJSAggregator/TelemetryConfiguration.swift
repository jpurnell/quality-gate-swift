import Foundation
import IJSSensor
import os
import Yams

/// Configuration for IJS telemetry aggregation.
///
/// Loaded from the `ijs:` section of `.quality-gate.yml` in the project root.
public struct TelemetryConfiguration: Sendable, Codable, Equatable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "TelemetryConfiguration")
    /// Repository or project identifier.
    public let projectID: String
    /// Absolute path to the telemetry corpus root directory.
    public let corpusPath: String
    /// The stakeholder who owns shipping decisions for this project.
    public let decisionOwner: String
    /// Default risk tier when not specified per-override.
    public let defaultRiskTier: RiskTier
    /// Whether this is a local or CI environment. Auto-detected if nil.
    public let environment: Environment?
    /// Configurable weights for the consistency scorer. Defaults to `ScorerWeights.defaults`.
    public let scorerWeights: ScorerWeights
    /// Documented exemptions from consistency finding matching.
    public let consistencyExemptions: [ConsistencyExemption]

    /// Creates a new telemetry configuration.
    public init(
        projectID: String,
        corpusPath: String,
        decisionOwner: String,
        defaultRiskTier: RiskTier,
        environment: Environment?,
        scorerWeights: ScorerWeights = .defaults,
        consistencyExemptions: [ConsistencyExemption] = []
    ) {
        self.projectID = projectID
        self.corpusPath = corpusPath
        self.decisionOwner = decisionOwner
        self.defaultRiskTier = defaultRiskTier
        self.environment = environment
        self.scorerWeights = scorerWeights
        self.consistencyExemptions = consistencyExemptions
    }

    /// Loads configuration from the `ijs:` section of a `.quality-gate.yml` file.
    ///
    /// - Parameter url: Path to the `.quality-gate.yml` file.
    /// - Throws: `IJSError.configurationError` if the file cannot be read or parsed.
    public static func load(from url: URL) throws -> TelemetryConfiguration {
        let yamlString: String
        do {
            yamlString = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw IJSError.configurationError(reason: "Cannot read file: \(error.localizedDescription)")
        }

        let root: [String: Any]
        do {
            guard let parsed = try Yams.load(yaml: yamlString) as? [String: Any] else {
                throw IJSError.configurationError(reason: "Invalid YAML structure")
            }
            root = parsed
        } catch let ijsError as IJSError {
            throw ijsError
        } catch {
            logger.warning("Failed to parse configuration YAML: \(error.localizedDescription, privacy: .public)")
            throw IJSError.configurationError(reason: "Invalid YAML structure: \(error.localizedDescription)")
        }

        guard let ijsSection = root["ijs"] as? [String: Any] else {
            throw IJSError.configurationError(reason: "Missing 'ijs' section in .quality-gate.yml")
        }

        guard let projectID = ijsSection["projectID"] as? String else {
            throw IJSError.configurationError(reason: "Missing 'projectID' in ijs section")
        }

        guard let corpusPath = ijsSection["corpusPath"] as? String else {
            throw IJSError.configurationError(reason: "Missing 'corpusPath' in ijs section")
        }

        guard let decisionOwner = ijsSection["decisionOwner"] as? String else {
            throw IJSError.configurationError(reason: "Missing 'decisionOwner' in ijs section")
        }

        guard let riskTierRaw = ijsSection["defaultRiskTier"] as? Int,
              let riskTier = RiskTier(rawValue: riskTierRaw) else {
            throw IJSError.configurationError(reason: "Missing or invalid 'defaultRiskTier' in ijs section")
        }

        let environment: Environment?
        if let envString = ijsSection["environment"] as? String {
            environment = Environment(rawValue: envString)
        } else {
            environment = nil
        }

        let scorerWeights: ScorerWeights
        if let weightsSection = ijsSection["scorerWeights"] as? [String: Any] {
            scorerWeights = ScorerWeights(
                clusterMatch: weightsSection["clusterMatch"] as? Double ?? ScorerWeights.defaults.clusterMatch,
                anomalyPattern: weightsSection["anomalyPattern"] as? Double ?? ScorerWeights.defaults.anomalyPattern,
                unaddressedPolicy: weightsSection["unaddressedPolicy"] as? Double ?? ScorerWeights.defaults.unaddressedPolicy,
                recurrenceBonus: weightsSection["recurrenceBonus"] as? Double ?? ScorerWeights.defaults.recurrenceBonus,
                suppressionPattern: weightsSection["suppressionPattern"] as? Double ?? ScorerWeights.defaults.suppressionPattern
            )
        } else {
            scorerWeights = .defaults
        }

        return TelemetryConfiguration(
            projectID: projectID,
            corpusPath: corpusPath,
            decisionOwner: decisionOwner,
            defaultRiskTier: riskTier,
            environment: environment,
            scorerWeights: scorerWeights
        )
    }
}
