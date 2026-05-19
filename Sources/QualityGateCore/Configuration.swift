import Foundation
import Yams

/// Configurable scorer weights for the consistency scoring algorithm.
///
/// Mirrors `ScorerWeights` from IJSSensor but lives in QualityGateCore
/// so Configuration doesn't depend on IJS modules.
///
/// ## YAML Example
/// ```yaml
/// consistency:
///   scorerWeights:
///     clusterMatch: 0.15
///     anomalyPattern: 0.10
///     unaddressedPolicy: 0.05
///     recurrenceBonus: 0.10
/// ```
public struct ScorerWeightsConfig: Sendable, Codable, Equatable {
    /// Weight for cluster match scoring.
    public let clusterMatch: Double
    /// Weight for anomaly pattern scoring.
    public let anomalyPattern: Double
    /// Weight for unaddressed policy scoring.
    public let unaddressedPolicy: Double
    /// Weight for recurrence bonus scoring.
    public let recurrenceBonus: Double

    /// Default scorer weight configuration.
    public static let defaults = ScorerWeightsConfig(
        clusterMatch: 0.15,
        anomalyPattern: 0.10,
        unaddressedPolicy: 0.05,
        recurrenceBonus: 0.10
    )

    /// Creates a scorer weights configuration with the specified values.
    public init(
        clusterMatch: Double,
        anomalyPattern: Double,
        unaddressedPolicy: Double,
        recurrenceBonus: Double
    ) {
        self.clusterMatch = clusterMatch
        self.anomalyPattern = anomalyPattern
        self.unaddressedPolicy = unaddressedPolicy
        self.recurrenceBonus = recurrenceBonus
    }
}

/// Per-checker configuration for ConsistencyChecker (IJS).
///
/// ## YAML Example
/// ```yaml
/// consistency:
///   corpusPath: .ijs-corpus
///   projectID: quality-gate-swift
///   consistencyThreshold: 0.7
///   defaultRiskTier: 2
///   exemptions: ["Generated/**"]
///   scorerWeights:
///     clusterMatch: 0.15
/// ```
public struct ConsistencyCheckerConfig: Sendable, Equatable {
    /// Path to the IJS corpus directory. nil means IJS is not configured.
    public let corpusPath: String?
    /// Project identifier for the corpus. nil derives from the working directory name.
    public let projectID: String?
    /// Consistency score below this threshold triggers a warning. Default: 0.7.
    public let consistencyThreshold: Double
    /// Default risk tier raw value (1–4) for telemetry metadata. Default: 2 (operational).
    public let defaultRiskTier: Int
    /// Custom scorer weights. nil uses ScorerWeights.defaults.
    public let scorerWeights: ScorerWeightsConfig?
    /// Module or path patterns exempt from consistency checks.
    public let exemptions: [String]

    /// Creates a consistency checker configuration with the specified values.
    public init(
        corpusPath: String? = nil,
        projectID: String? = nil,
        consistencyThreshold: Double = 0.7,
        defaultRiskTier: Int = 2,
        scorerWeights: ScorerWeightsConfig? = nil,
        exemptions: [String] = []
    ) {
        self.corpusPath = corpusPath
        self.projectID = projectID
        self.consistencyThreshold = consistencyThreshold
        self.defaultRiskTier = defaultRiskTier
        self.scorerWeights = scorerWeights
        self.exemptions = exemptions
    }

    /// Default consistency checker configuration.
    public static let `default` = ConsistencyCheckerConfig()
}

extension ConsistencyCheckerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case corpusPath, projectID, consistencyThreshold, defaultRiskTier, scorerWeights, exemptions
    }

    /// Creates a configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ConsistencyCheckerConfig.default
        corpusPath = try container.decodeIfPresent(String.self, forKey: .corpusPath) ?? defaults.corpusPath
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID) ?? defaults.projectID
        consistencyThreshold = try container.decodeIfPresent(Double.self, forKey: .consistencyThreshold) ?? defaults.consistencyThreshold
        defaultRiskTier = try container.decodeIfPresent(Int.self, forKey: .defaultRiskTier) ?? defaults.defaultRiskTier
        scorerWeights = try container.decodeIfPresent(ScorerWeightsConfig.self, forKey: .scorerWeights) ?? defaults.scorerWeights
        exemptions = try container.decodeIfPresent([String].self, forKey: .exemptions) ?? defaults.exemptions
    }
}

/// Per-checker configuration for ConcurrencyAuditor.
public struct ConcurrencyAuditorConfig: Sendable, Equatable {
    /// Comment keyword that suppresses unchecked-Sendable / nonisolated-unsafe rules.
    public let justificationKeyword: String
    /// Module names that are allowed to keep `@preconcurrency import` even if first-party.
    public let allowPreconcurrencyImports: [String]

    /// Creates a concurrency auditor configuration with the given options.
    public init(
        justificationKeyword: String = "Justification:",
        allowPreconcurrencyImports: [String] = []
    ) {
        self.justificationKeyword = justificationKeyword
        self.allowPreconcurrencyImports = allowPreconcurrencyImports
    }

    /// Default concurrency auditor configuration.
    public static let `default` = ConcurrencyAuditorConfig()
}

extension ConcurrencyAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case justificationKeyword, allowPreconcurrencyImports
    }

    /// Creates a concurrency auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ConcurrencyAuditorConfig.default
        justificationKeyword = try container.decodeIfPresent(String.self, forKey: .justificationKeyword) ?? defaults.justificationKeyword
        allowPreconcurrencyImports = try container.decodeIfPresent([String].self, forKey: .allowPreconcurrencyImports) ?? defaults.allowPreconcurrencyImports
    }
}

/// Per-checker configuration for PointerEscapeAuditor.
public struct PointerEscapeAuditorConfig: Sendable, Equatable {
    /// Function names allowed to receive a borrowed pointer (escape suppression).
    public let allowedEscapeFunctions: [String]

    /// Creates a pointer-escape auditor configuration with the given options.
    public init(allowedEscapeFunctions: [String] = []) {
        self.allowedEscapeFunctions = allowedEscapeFunctions
    }

    /// Default pointer-escape auditor configuration.
    public static let `default` = PointerEscapeAuditorConfig()
}

extension PointerEscapeAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case allowedEscapeFunctions
    }

    /// Creates a pointer-escape auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowedEscapeFunctions = try container.decodeIfPresent([String].self, forKey: .allowedEscapeFunctions) ?? PointerEscapeAuditorConfig.default.allowedEscapeFunctions
    }
}

/// Per-checker configuration for SecurityVisitor (within SafetyAuditor).
///
/// Controls which security rules are enabled and how they detect patterns.
///
/// ## YAML Example
/// ```yaml
/// security:
///   enabledRules: []
///   secretPatterns: ["password", "secret", "apiKey", "token"]
///   allowedHTTPHosts: ["localhost", "127.0.0.1"]
///   sqlFunctionNames: ["execute", "prepare", "query"]
/// ```
public struct SecurityAuditorConfig: Sendable, Equatable {
    /// Which security rules to enable. Empty means all rules are enabled.
    public let enabledRules: [String]

    /// Regex patterns for variable names that indicate secrets.
    public let secretPatterns: [String]

    /// Hosts allowed to use http:// (e.g. localhost test servers).
    public let allowedHTTPHosts: [String]

    /// SQL-executing function names that trigger the sql-injection rule.
    public let sqlFunctionNames: [String]

    /// Creates a security auditor configuration with the given options.
    public init(
        enabledRules: [String] = [],
        secretPatterns: [String] = [
            "password", "secret", "apiKey", "api_key", "apikey",
            "token", "credential", "privateKey", "private_key", "privatekey"
        ],
        allowedHTTPHosts: [String] = ["localhost", "127.0.0.1", "0.0.0.0"],
        sqlFunctionNames: [String] = [
            "execute", "prepare", "query", "rawQuery",
            "sqlite3_exec", "sqlite3_prepare"
        ]
    ) {
        self.enabledRules = enabledRules
        self.secretPatterns = secretPatterns
        self.allowedHTTPHosts = allowedHTTPHosts
        self.sqlFunctionNames = sqlFunctionNames
    }

    /// Default security auditor configuration.
    public static let `default` = SecurityAuditorConfig()
}

extension SecurityAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case enabledRules, secretPatterns, allowedHTTPHosts, sqlFunctionNames
    }

    /// Creates a security auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SecurityAuditorConfig.default
        enabledRules = try container.decodeIfPresent([String].self, forKey: .enabledRules) ?? defaults.enabledRules
        secretPatterns = try container.decodeIfPresent([String].self, forKey: .secretPatterns) ?? defaults.secretPatterns
        allowedHTTPHosts = try container.decodeIfPresent([String].self, forKey: .allowedHTTPHosts) ?? defaults.allowedHTTPHosts
        sqlFunctionNames = try container.decodeIfPresent([String].self, forKey: .sqlFunctionNames) ?? defaults.sqlFunctionNames
    }
}

/// Per-checker configuration for StatusAuditor.
///
/// Controls paths to status documents and validation thresholds.
///
/// ## YAML Example
/// ```yaml
/// status:
///   guidelinesPath: development-guidelines
///   masterPlanPath: 00_CORE_RULES/00_MASTER_PLAN.md
///   stubThresholdLines: 50
///   testCountDriftPercent: 10
///   lastUpdatedStaleDays: 90
/// ```
public struct StatusAuditorConfig: Sendable, Equatable {
    /// Path to development-guidelines directory relative to project root.
    public let guidelinesPath: String

    /// Path to Master Plan relative to the guidelines directory.
    public let masterPlanPath: String

    /// Minimum source lines to consider a module "implemented" (not a stub).
    public let stubThresholdLines: Int

    /// Maximum allowed percentage difference between documented and actual test counts.
    public let testCountDriftPercent: Int

    /// Maximum days since "Last Updated" before flagging staleness.
    public let lastUpdatedStaleDays: Int

    /// Creates a status auditor configuration with the given options.
    public init(
        guidelinesPath: String = "development-guidelines",
        masterPlanPath: String = "00_CORE_RULES/00_MASTER_PLAN.md",
        stubThresholdLines: Int = 50,
        testCountDriftPercent: Int = 10,
        lastUpdatedStaleDays: Int = 90
    ) {
        self.guidelinesPath = guidelinesPath
        self.masterPlanPath = masterPlanPath
        self.stubThresholdLines = stubThresholdLines
        self.testCountDriftPercent = testCountDriftPercent
        self.lastUpdatedStaleDays = lastUpdatedStaleDays
    }

    /// Default status auditor configuration.
    public static let `default` = StatusAuditorConfig()
}

extension StatusAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case guidelinesPath, masterPlanPath, stubThresholdLines, testCountDriftPercent, lastUpdatedStaleDays
    }

    /// Creates a status auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StatusAuditorConfig.default
        guidelinesPath = try container.decodeIfPresent(String.self, forKey: .guidelinesPath) ?? defaults.guidelinesPath
        masterPlanPath = try container.decodeIfPresent(String.self, forKey: .masterPlanPath) ?? defaults.masterPlanPath
        stubThresholdLines = try container.decodeIfPresent(Int.self, forKey: .stubThresholdLines) ?? defaults.stubThresholdLines
        testCountDriftPercent = try container.decodeIfPresent(Int.self, forKey: .testCountDriftPercent) ?? defaults.testCountDriftPercent
        lastUpdatedStaleDays = try container.decodeIfPresent(Int.self, forKey: .lastUpdatedStaleDays) ?? defaults.lastUpdatedStaleDays
    }
}

/// Per-checker configuration for SwiftVersionChecker.
///
/// Controls the minimum required `swift-tools-version` and whether
/// the local compiler version is also reported.
///
/// ## YAML Example
/// ```yaml
/// swiftVersion:
///   minimum: "6.2"
///   checkCompiler: true
/// ```
public struct SwiftVersionConfig: Sendable, Equatable {
    /// Minimum required swift-tools-version (e.g. "6.2").
    public let minimum: String

    /// Whether to also check and report the local compiler version.
    public let checkCompiler: Bool

    /// Creates a Swift version configuration with the given options.
    public init(
        minimum: String = "6.2",
        checkCompiler: Bool = true
    ) {
        self.minimum = minimum
        self.checkCompiler = checkCompiler
    }

    /// Default Swift version configuration.
    public static let `default` = SwiftVersionConfig()
}

extension SwiftVersionConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case minimum, checkCompiler
    }

    /// Creates a Swift version configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SwiftVersionConfig.default
        minimum = try container.decodeIfPresent(String.self, forKey: .minimum) ?? defaults.minimum
        checkCompiler = try container.decodeIfPresent(Bool.self, forKey: .checkCompiler) ?? defaults.checkCompiler
    }
}

/// Per-checker configuration for MemoryBuilder.
public struct MemoryBuilderConfig: Sendable, Equatable {
    /// Relative path to the development-guidelines directory.
    public let guidelinesPath: String

    /// Creates a memory builder configuration with the given options.
    public init(guidelinesPath: String = "development-guidelines") {
        self.guidelinesPath = guidelinesPath
    }

    /// Default memory builder configuration.
    public static let `default` = MemoryBuilderConfig()
}

extension MemoryBuilderConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case guidelinesPath
    }

    /// Creates a memory builder configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guidelinesPath = try container.decodeIfPresent(String.self, forKey: .guidelinesPath) ?? MemoryBuilderConfig.default.guidelinesPath
    }
}

/// Per-checker configuration for LoggingAuditor.
///
/// Controls whether logging hygiene checks run (apps only, not libraries)
/// and how silent `try?` expressions are evaluated.
///
/// ## YAML Example
/// ```yaml
/// logging:
///   projectType: application
///   silentTryKeyword: "silent:"
///   allowedSilentTryFunctions: ["Task.sleep", "JSONEncoder", "JSONDecoder"]
///   customLoggerNames: ["NarbisLog", "WatchLog"]
/// ```
public struct LoggingAuditorConfig: Sendable, Equatable {
    /// Project type: "application" enables all rules, "library" skips the auditor entirely.
    public let projectType: String

    /// Comment keyword that suppresses silent-try warnings.
    public let silentTryKeyword: String

    /// Function names where `try?` is considered safe (fire-and-forget patterns).
    public let allowedSilentTryFunctions: [String]

    /// Additional logger type names beyond os.Logger (e.g. project-specific wrappers).
    public let customLoggerNames: [String]

    /// Creates a logging auditor configuration with the given options.
    public init(
        projectType: String = "application",
        silentTryKeyword: String = "silent:",
        allowedSilentTryFunctions: [String] = ["Task.sleep", "JSONEncoder", "JSONDecoder"],
        customLoggerNames: [String] = []
    ) {
        self.projectType = projectType
        self.silentTryKeyword = silentTryKeyword
        self.allowedSilentTryFunctions = allowedSilentTryFunctions
        self.customLoggerNames = customLoggerNames
    }

    /// Default logging auditor configuration.
    public static let `default` = LoggingAuditorConfig()
}

extension LoggingAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case projectType, silentTryKeyword, allowedSilentTryFunctions, customLoggerNames
    }

    /// Creates a logging auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LoggingAuditorConfig.default
        projectType = try container.decodeIfPresent(String.self, forKey: .projectType) ?? defaults.projectType
        silentTryKeyword = try container.decodeIfPresent(String.self, forKey: .silentTryKeyword) ?? defaults.silentTryKeyword
        allowedSilentTryFunctions = try container.decodeIfPresent([String].self, forKey: .allowedSilentTryFunctions) ?? defaults.allowedSilentTryFunctions
        customLoggerNames = try container.decodeIfPresent([String].self, forKey: .customLoggerNames) ?? defaults.customLoggerNames
    }
}

/// Per-checker configuration for DependencyAuditor.
public struct DependencyAuditorConfig: Sendable, Equatable {
    /// Maximum major versions behind latest before flagging.
    public let maxMajorVersionsBehind: Int

    /// Branch pins that are explicitly allowed.
    public let allowBranchPins: [String]

    /// Skip network calls to check latest tags.
    public let offlineMode: Bool

    /// Creates a dependency auditor configuration with the given options.
    public init(
        maxMajorVersionsBehind: Int = 2,
        allowBranchPins: [String] = [],
        offlineMode: Bool = false
    ) {
        self.maxMajorVersionsBehind = maxMajorVersionsBehind
        self.allowBranchPins = allowBranchPins
        self.offlineMode = offlineMode
    }

    /// Default dependency auditor configuration.
    public static let `default` = DependencyAuditorConfig()
}

extension DependencyAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case maxMajorVersionsBehind, allowBranchPins, offlineMode
    }

    /// Creates a dependency auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DependencyAuditorConfig.default
        maxMajorVersionsBehind = try container.decodeIfPresent(Int.self, forKey: .maxMajorVersionsBehind) ?? defaults.maxMajorVersionsBehind
        allowBranchPins = try container.decodeIfPresent([String].self, forKey: .allowBranchPins) ?? defaults.allowBranchPins
        offlineMode = try container.decodeIfPresent(Bool.self, forKey: .offlineMode) ?? defaults.offlineMode
    }
}

/// Per-checker configuration for ReleaseReadinessAuditor.
public struct ReleaseReadinessAuditorConfig: Sendable, Equatable {
    /// Path to CHANGELOG file relative to project root.
    public let changelogPath: String

    /// Path to README file relative to project root.
    public let readmePath: String

    /// Whether TODO/FIXME in source files require issue references.
    public let requireIssueReference: Bool

    /// Additional marker patterns to flag beyond TODO/FIXME/HACK/XXX.
    public let additionalMarkers: [String]

    /// Creates a release readiness auditor configuration with the given options.
    public init(
        changelogPath: String = "CHANGELOG.md",
        readmePath: String = "README.md",
        requireIssueReference: Bool = false,
        additionalMarkers: [String] = []
    ) {
        self.changelogPath = changelogPath
        self.readmePath = readmePath
        self.requireIssueReference = requireIssueReference
        self.additionalMarkers = additionalMarkers
    }

    /// Default release readiness auditor configuration.
    public static let `default` = ReleaseReadinessAuditorConfig()
}

extension ReleaseReadinessAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case changelogPath, readmePath, requireIssueReference, additionalMarkers
    }

    /// Creates a release readiness auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReleaseReadinessAuditorConfig.default
        changelogPath = try container.decodeIfPresent(String.self, forKey: .changelogPath) ?? defaults.changelogPath
        readmePath = try container.decodeIfPresent(String.self, forKey: .readmePath) ?? defaults.readmePath
        requireIssueReference = try container.decodeIfPresent(Bool.self, forKey: .requireIssueReference) ?? defaults.requireIssueReference
        additionalMarkers = try container.decodeIfPresent([String].self, forKey: .additionalMarkers) ?? defaults.additionalMarkers
    }
}

/// Per-checker configuration for FloatingPointSafetyAuditor.
public struct FloatingPointSafetyAuditorConfig: Sendable, Equatable {
    /// Files to exclude from FP safety checks.
    public let allowedFiles: [String]

    /// Whether to check for unguarded division.
    public let checkDivisionGuards: Bool

    /// Creates a floating-point safety auditor configuration with the given options.
    public init(
        allowedFiles: [String] = [],
        checkDivisionGuards: Bool = true
    ) {
        self.allowedFiles = allowedFiles
        self.checkDivisionGuards = checkDivisionGuards
    }

    /// Default floating-point safety auditor configuration.
    public static let `default` = FloatingPointSafetyAuditorConfig()
}

extension FloatingPointSafetyAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case allowedFiles, checkDivisionGuards
    }

    /// Creates a floating-point safety auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FloatingPointSafetyAuditorConfig.default
        allowedFiles = try container.decodeIfPresent([String].self, forKey: .allowedFiles) ?? defaults.allowedFiles
        checkDivisionGuards = try container.decodeIfPresent(Bool.self, forKey: .checkDivisionGuards) ?? defaults.checkDivisionGuards
    }
}

/// Per-checker configuration for StochasticDeterminismAuditor.
public struct StochasticDeterminismConfig: Sendable, Equatable {
    /// Function names exempt from seed requirement.
    public let exemptFunctions: [String]

    /// Files exempt from stochastic checks.
    public let exemptFiles: [String]

    /// Whether to flag collection `.shuffled()` without `using:` parameter.
    public let flagCollectionShuffle: Bool

    /// Whether to flag global C-style random state (`drand48`, `arc4random`).
    public let flagGlobalState: Bool

    /// Creates a stochastic determinism configuration with the given options.
    public init(
        exemptFunctions: [String] = [],
        exemptFiles: [String] = [],
        flagCollectionShuffle: Bool = true,
        flagGlobalState: Bool = true
    ) {
        self.exemptFunctions = exemptFunctions
        self.exemptFiles = exemptFiles
        self.flagCollectionShuffle = flagCollectionShuffle
        self.flagGlobalState = flagGlobalState
    }

    /// Default stochastic determinism configuration.
    public static let `default` = StochasticDeterminismConfig()
}

extension StochasticDeterminismConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case exemptFunctions, exemptFiles, flagCollectionShuffle, flagGlobalState
    }

    /// Creates a stochastic determinism configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StochasticDeterminismConfig.default
        exemptFunctions = try container.decodeIfPresent([String].self, forKey: .exemptFunctions) ?? defaults.exemptFunctions
        exemptFiles = try container.decodeIfPresent([String].self, forKey: .exemptFiles) ?? defaults.exemptFiles
        flagCollectionShuffle = try container.decodeIfPresent(Bool.self, forKey: .flagCollectionShuffle) ?? defaults.flagCollectionShuffle
        flagGlobalState = try container.decodeIfPresent(Bool.self, forKey: .flagGlobalState) ?? defaults.flagGlobalState
    }
}

/// Per-checker configuration for MemoryLifecycleGuard.
public struct MemoryLifecycleConfig: Sendable, Equatable {
    /// Property name patterns that indicate delegate/parent references.
    public let delegatePatterns: [String]

    /// Whether to require Task cancellation in deinit.
    public let requireTaskCancellation: Bool

    /// Files exempt from lifecycle checks.
    public let exemptFiles: [String]

    /// Type names whose construction inside loops requires autoreleasepool.
    public let heavyFrameworkTypes: [String]

    /// File patterns exempt from the loop-growth rule.
    public let loopGrowthExemptPatterns: [String]

    /// Creates a memory lifecycle configuration with the given options.
    public init(
        delegatePatterns: [String] = ["delegate", "parent", "owner", "dataSource"],
        requireTaskCancellation: Bool = true,
        exemptFiles: [String] = [],
        heavyFrameworkTypes: [String] = [
            "MLXArray", "MTLBuffer", "MTLTexture",
            "CGImage", "CGContext", "CVPixelBuffer"
        ],
        loopGrowthExemptPatterns: [String] = []
    ) {
        self.delegatePatterns = delegatePatterns
        self.requireTaskCancellation = requireTaskCancellation
        self.exemptFiles = exemptFiles
        self.heavyFrameworkTypes = heavyFrameworkTypes
        self.loopGrowthExemptPatterns = loopGrowthExemptPatterns
    }

    /// Default memory lifecycle configuration.
    public static let `default` = MemoryLifecycleConfig()
}

extension MemoryLifecycleConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case delegatePatterns, requireTaskCancellation, exemptFiles
        case heavyFrameworkTypes, loopGrowthExemptPatterns
    }

    /// Creates a memory lifecycle configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MemoryLifecycleConfig.default
        delegatePatterns = try container.decodeIfPresent([String].self, forKey: .delegatePatterns) ?? defaults.delegatePatterns
        requireTaskCancellation = try container.decodeIfPresent(Bool.self, forKey: .requireTaskCancellation) ?? defaults.requireTaskCancellation
        exemptFiles = try container.decodeIfPresent([String].self, forKey: .exemptFiles) ?? defaults.exemptFiles
        heavyFrameworkTypes = try container.decodeIfPresent([String].self, forKey: .heavyFrameworkTypes) ?? defaults.heavyFrameworkTypes
        loopGrowthExemptPatterns = try container.decodeIfPresent([String].self, forKey: .loopGrowthExemptPatterns) ?? defaults.loopGrowthExemptPatterns
    }
}

/// Per-checker configuration for MCPReadinessAuditor.
public struct MCPReadinessConfig: Sendable, Equatable {
    /// Whether the MCP readiness checker is enabled.
    public let enabled: Bool

    /// Minimum character length for tool and property descriptions.
    public let minDescriptionLength: Int

    /// Additional source directories to scan for MCP tools.
    public let additionalPaths: [String]

    /// Source directories to exclude from scanning.
    public let excludePaths: [String]

    /// Creates an MCP readiness configuration with the given options.
    public init(
        enabled: Bool = false,
        minDescriptionLength: Int = 10,
        additionalPaths: [String] = [],
        excludePaths: [String] = []
    ) {
        self.enabled = enabled
        self.minDescriptionLength = minDescriptionLength
        self.additionalPaths = additionalPaths
        self.excludePaths = excludePaths
    }

    /// Default MCP readiness configuration.
    public static let `default` = MCPReadinessConfig()
}

extension MCPReadinessConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case enabled, minDescriptionLength, additionalPaths, excludePaths
    }

    /// Creates an MCP readiness configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MCPReadinessConfig.default
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        minDescriptionLength = try container.decodeIfPresent(Int.self, forKey: .minDescriptionLength) ?? defaults.minDescriptionLength
        additionalPaths = try container.decodeIfPresent([String].self, forKey: .additionalPaths) ?? defaults.additionalPaths
        excludePaths = try container.decodeIfPresent([String].self, forKey: .excludePaths) ?? defaults.excludePaths
    }
}

/// A user-declared cost for a function pattern.
///
/// Used in `.quality-gate.yml` to declare known Big-O costs for project-specific
/// or third-party library calls that the complexity analyzer cannot infer from AST alone.
///
/// ## YAML Example
/// ```yaml
/// complexity:
///   knownCosts:
///     - pattern: "DatabaseClient.fetch"
///       cost: "O(n)"
///     - pattern: "Cache.lookup"
///       cost: "O(1)"
/// ```
public struct KnownCostEntry: Sendable, Equatable, Codable {
    /// Function name or pattern to match (e.g., "DatabaseClient.fetch", "Cache.lookup").
    public let pattern: String
    /// The known Big-O cost (e.g., "O(n)", "O(1)", "O(n log n)").
    public let cost: String

    /// Creates a known cost entry with the specified pattern and cost.
    public init(pattern: String, cost: String) {
        self.pattern = pattern
        self.cost = cost
    }
}

/// Per-checker configuration for ComplexityAnalyzer (advisory).
///
/// ## YAML Example
/// ```yaml
/// complexity:
///   cognitiveThreshold: 15
///   reportTopN: 10
///   moduleThresholds:
///     Parser: 25
///     Utilities: 10
///   emitToCorpus: true
///   callGraphEnabled: true
///   callGraphMaxDepth: 1
///   knownCosts:
///     - pattern: "DatabaseClient.fetch"
///       cost: "O(n)"
/// ```
public struct ComplexityAnalyzerConfig: Sendable, Equatable {
    /// Default cognitive complexity threshold for flagging functions.
    public let cognitiveThreshold: Int

    /// Number of top-complexity functions to include in reports.
    public let reportTopN: Int

    /// Per-module threshold overrides (module name to threshold).
    public let moduleThresholds: [String: Int]

    /// Whether to emit complexity data to the IJS corpus.
    public let emitToCorpus: Bool

    /// Whether to enable call-graph amplification (cross-function cost composition).
    public let callGraphEnabled: Bool

    /// Maximum transitive depth for call-graph amplification (1 = direct calls only).
    public let callGraphMaxDepth: Int

    /// User-declared function costs for project-specific or third-party operations.
    public let knownCosts: [KnownCostEntry]

    /// Creates a complexity analyzer configuration with the given options.
    public init(
        cognitiveThreshold: Int = 15,
        reportTopN: Int = 10,
        moduleThresholds: [String: Int] = [:],
        emitToCorpus: Bool = true,
        callGraphEnabled: Bool = true,
        callGraphMaxDepth: Int = 1,
        knownCosts: [KnownCostEntry] = []
    ) {
        self.cognitiveThreshold = cognitiveThreshold
        self.reportTopN = reportTopN
        self.moduleThresholds = moduleThresholds
        self.emitToCorpus = emitToCorpus
        self.callGraphEnabled = callGraphEnabled
        self.callGraphMaxDepth = callGraphMaxDepth
        self.knownCosts = knownCosts
    }

    /// Default complexity analyzer configuration.
    public static let `default` = ComplexityAnalyzerConfig()
}

extension ComplexityAnalyzerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case cognitiveThreshold, reportTopN, moduleThresholds, emitToCorpus
        case callGraphEnabled, callGraphMaxDepth, knownCosts
    }

    /// Creates a complexity analyzer configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ComplexityAnalyzerConfig.default
        cognitiveThreshold = try container.decodeIfPresent(Int.self, forKey: .cognitiveThreshold) ?? defaults.cognitiveThreshold
        reportTopN = try container.decodeIfPresent(Int.self, forKey: .reportTopN) ?? defaults.reportTopN
        moduleThresholds = try container.decodeIfPresent([String: Int].self, forKey: .moduleThresholds) ?? defaults.moduleThresholds
        emitToCorpus = try container.decodeIfPresent(Bool.self, forKey: .emitToCorpus) ?? defaults.emitToCorpus
        callGraphEnabled = try container.decodeIfPresent(Bool.self, forKey: .callGraphEnabled) ?? defaults.callGraphEnabled
        callGraphMaxDepth = try container.decodeIfPresent(Int.self, forKey: .callGraphMaxDepth) ?? defaults.callGraphMaxDepth
        knownCosts = try container.decodeIfPresent([KnownCostEntry].self, forKey: .knownCosts) ?? defaults.knownCosts
    }
}

/// Per-checker configuration for BuildChecker.
///
/// Controls how the `swift build` invocation is tuned, including the
/// per-expression type-check time limit that catches compound generic
/// expressions which compile locally but time out on CI.
///
/// ## YAML Example
/// ```yaml
/// build:
///   solverExpressionTimeThreshold: 500
/// ```
public struct BuildCheckerConfig: Sendable, Equatable {
    /// Per-expression type-check millisecond limit passed to the compiler
    /// via `-Xfrontend -solver-expression-time-threshold`.
    /// nil means no limit (compiler default).
    public let solverExpressionTimeThreshold: Int?

    /// Creates a build checker configuration with the given options.
    public init(solverExpressionTimeThreshold: Int? = nil) {
        self.solverExpressionTimeThreshold = solverExpressionTimeThreshold
    }

    /// Default build checker configuration (no threshold).
    public static let `default` = BuildCheckerConfig()
}

extension BuildCheckerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case solverExpressionTimeThreshold
    }

    /// Creates a build checker configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        solverExpressionTimeThreshold = try container.decodeIfPresent(Int.self, forKey: .solverExpressionTimeThreshold)
    }
}

/// Severity override level for a diagnostic rule.
///
/// Used in `.quality-gate.yml` to override the severity of specific rules
/// after checkers produce their results. The `.off` case suppresses
/// the diagnostic entirely.
///
/// ## YAML Example
/// ```yaml
/// overrides:
///   safety.force-unwrap: warning
///   doc-coverage.*: off
///   context.missing-consent-guard: error
/// ```
public enum SeverityOverride: String, Sendable, Codable, Equatable {
    /// Escalate to error severity.
    case error
    /// Downgrade to warning severity.
    case warning
    /// Downgrade to informational note severity.
    case info
    /// Suppress the diagnostic entirely.
    case off
}

/// Project-specific configuration for quality checks.
///
/// Configuration can be loaded from a `.quality-gate.yml` file in the project root,
/// or constructed programmatically.
///
/// ## YAML Example
/// ```yaml
/// parallelWorkers: 8
/// excludePatterns:
///   - "**/Generated/**"
///   - "**/Vendor/**"
/// safetyExemptions:
///   - "// SAFETY:"
/// enabledCheckers:
///   - build
///   - test
///   - safety
///   - recursion
///   - concurrency
///   - pointer-escape
/// concurrency:
///   justificationKeyword: "Justification:"
///   allowPreconcurrencyImports:
///     - Alamofire
/// pointerEscape:
///   allowedEscapeFunctions:
///     - vDSP_fft_zip
///     - vDSP_fft_zop
/// ```
public struct Configuration: Sendable, Codable, Equatable {

    /// Number of parallel workers for test execution.
    /// If nil, defaults to 80% of system cores.
    public let parallelWorkers: Int?

    /// Glob patterns for files/directories to exclude from checks.
    public let excludePatterns: [String]

    /// Comment patterns that suppress safety warnings.
    public let safetyExemptions: [String]

    /// Checkers to run. Empty means all checkers are enabled.
    public let enabledCheckers: [String]

    /// Build configuration to use (debug or release). Defaults to debug.
    public let buildConfiguration: String?

    /// Test filter pattern for running specific tests.
    public let testFilter: String?

    /// Documentation target for DocC linting.
    /// If nil, auto-detects the first library product target from Package.swift.
    public let docTarget: String?

    /// Minimum documentation coverage percentage (0-100).
    /// If nil, any undocumented public API triggers a warning.
    /// If set, coverage below threshold triggers failure, otherwise passes.
    public let docCoverageThreshold: Int?

    /// v5: Opt in to driving `xcodebuild build` automatically when the
    /// `unreachable` checker can't find a fresh DerivedData index store
    /// for an Xcode project. Default: false (slow + side-effect-y).
    public let unreachableAutoBuildXcode: Bool

    /// v5: Override the auto-detected scheme for `xcodebuild`. nil ⇒
    /// pick the first scheme reported by `xcodebuild -list -json`.
    public let xcodeScheme: String?

    /// v5: Override the auto-build destination. Default
    /// `"generic/platform=macOS"`.
    public let xcodeDestination: String?

    /// Per-checker configuration for ConcurrencyAuditor.
    public let concurrency: ConcurrencyAuditorConfig

    /// Per-checker configuration for PointerEscapeAuditor.
    public let pointerEscape: PointerEscapeAuditorConfig

    /// Per-checker configuration for SecurityVisitor (within SafetyAuditor).
    public let security: SecurityAuditorConfig

    /// Per-checker configuration for StatusAuditor.
    public let status: StatusAuditorConfig

    /// Per-checker configuration for SwiftVersionChecker.
    public let swiftVersion: SwiftVersionConfig

    /// Per-checker configuration for MemoryBuilder.
    public let memoryBuilder: MemoryBuilderConfig

    /// Per-checker configuration for LoggingAuditor.
    public let logging: LoggingAuditorConfig

    /// Per-checker configuration for DependencyAuditor.
    public let dependencyAudit: DependencyAuditorConfig

    /// Per-checker configuration for ReleaseReadinessAuditor.
    public let releaseReadiness: ReleaseReadinessAuditorConfig

    /// Per-checker configuration for FloatingPointSafetyAuditor.
    public let fpSafety: FloatingPointSafetyAuditorConfig

    /// Per-checker configuration for StochasticDeterminismAuditor.
    public let stochasticDeterminism: StochasticDeterminismConfig

    /// Per-checker configuration for MemoryLifecycleGuard.
    public let memoryLifecycle: MemoryLifecycleConfig

    /// Per-checker configuration for MCPReadinessAuditor.
    public let mcpReadiness: MCPReadinessConfig

    /// Per-checker configuration for BuildChecker.
    public let build: BuildCheckerConfig

    /// Per-checker configuration for ConsistencyChecker (IJS).
    public let consistency: ConsistencyCheckerConfig

    /// Per-checker configuration for ComplexityAnalyzer (advisory).
    public var complexity: ComplexityAnalyzerConfig

    /// Per-rule severity overrides from configuration.
    ///
    /// Keys are rule IDs (e.g. `"safety.force-unwrap"`) or wildcard patterns
    /// (e.g. `"safety.*"`). Applied after checkers return results, before reporting.
    public let overrides: [String: SeverityOverride]

    /// Creates a new configuration with the specified values.
    public init(
        parallelWorkers: Int? = nil,
        excludePatterns: [String] = [],
        safetyExemptions: [String] = ["// SAFETY:"],
        enabledCheckers: [String] = [],
        buildConfiguration: String? = nil,
        testFilter: String? = nil,
        docTarget: String? = nil,
        docCoverageThreshold: Int? = nil,
        unreachableAutoBuildXcode: Bool = false,
        xcodeScheme: String? = nil,
        xcodeDestination: String? = nil,
        concurrency: ConcurrencyAuditorConfig = .default,
        pointerEscape: PointerEscapeAuditorConfig = .default,
        security: SecurityAuditorConfig = .default,
        status: StatusAuditorConfig = .default,
        swiftVersion: SwiftVersionConfig = .default,
        memoryBuilder: MemoryBuilderConfig = .default,
        logging: LoggingAuditorConfig = .default,
        dependencyAudit: DependencyAuditorConfig = .default,
        releaseReadiness: ReleaseReadinessAuditorConfig = .default,
        fpSafety: FloatingPointSafetyAuditorConfig = .default,
        stochasticDeterminism: StochasticDeterminismConfig = .default,
        memoryLifecycle: MemoryLifecycleConfig = .default,
        mcpReadiness: MCPReadinessConfig = .default,
        build: BuildCheckerConfig = .default,
        consistency: ConsistencyCheckerConfig = .default,
        complexity: ComplexityAnalyzerConfig = .default,
        overrides: [String: SeverityOverride] = [:]
    ) {
        self.parallelWorkers = parallelWorkers
        self.excludePatterns = excludePatterns
        self.safetyExemptions = safetyExemptions
        self.enabledCheckers = enabledCheckers
        self.buildConfiguration = buildConfiguration
        self.testFilter = testFilter
        self.docTarget = docTarget
        self.docCoverageThreshold = docCoverageThreshold
        self.unreachableAutoBuildXcode = unreachableAutoBuildXcode
        self.xcodeScheme = xcodeScheme
        self.xcodeDestination = xcodeDestination
        self.concurrency = concurrency
        self.pointerEscape = pointerEscape
        self.security = security
        self.status = status
        self.swiftVersion = swiftVersion
        self.memoryBuilder = memoryBuilder
        self.logging = logging
        self.dependencyAudit = dependencyAudit
        self.releaseReadiness = releaseReadiness
        self.fpSafety = fpSafety
        self.stochasticDeterminism = stochasticDeterminism
        self.memoryLifecycle = memoryLifecycle
        self.mcpReadiness = mcpReadiness
        self.build = build
        self.consistency = consistency
        self.complexity = complexity
        self.overrides = overrides
    }

    /// The effective number of workers, either from config or computed.
    public var effectiveWorkers: Int {
        if let workers = parallelWorkers {
            return max(1, workers)
        }
        let cores = ProcessInfo.processInfo.processorCount
        return max(1, Int(Double(cores) * 0.8))
    }

    /// Whether a specific checker is enabled.
    ///
    /// - Parameter checkerId: The checker's identifier.
    /// - Returns: true if the checker should run.
    public func isCheckerEnabled(_ checkerId: String) -> Bool {
        // Empty list means all checkers are enabled
        enabledCheckers.isEmpty || enabledCheckers.contains(checkerId)
    }

    /// Parses configuration from a YAML string.
    ///
    /// - Parameter yaml: The YAML content.
    /// - Returns: The parsed configuration.
    /// - Throws: `QualityGateError.configurationError` if parsing fails.
    public static func from(yaml: String) throws -> Configuration {
        do {
            let decoder = YAMLDecoder()
            return try decoder.decode(Configuration.self, from: yaml)
        } catch {
            throw QualityGateError.configurationError("Invalid YAML: \(error.localizedDescription)")
        }
    }

    /// Loads configuration from a file path.
    ///
    /// - Parameter path: Path to the YAML configuration file.
    /// - Returns: The loaded configuration, or default if file not found.
    /// - Throws: `QualityGateError.configurationError` if file exists but is invalid.
    public static func load(from path: String) throws -> Configuration {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: path) else { // SAFETY: CLI tool reads local config file
            // Return default configuration if file doesn't exist
            return Configuration()
        }

        do {
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            return try from(yaml: contents)
        } catch let error as QualityGateError {
            throw error
        } catch {
            throw QualityGateError.configurationError("Failed to read config: \(error.localizedDescription)")
        }
    }
}

// MARK: - Custom Decoding for Optional Fields

extension Configuration {
    private enum CodingKeys: String, CodingKey {
        case parallelWorkers
        case excludePatterns
        case safetyExemptions
        case enabledCheckers
        case buildConfiguration
        case testFilter
        case docTarget
        case docCoverageThreshold
        case unreachableAutoBuildXcode
        case xcodeScheme
        case xcodeDestination
        case concurrency
        case pointerEscape
        case security
        case status
        case swiftVersion
        case memoryBuilder
        case logging
        case dependencyAudit
        case releaseReadiness
        case fpSafety
        case stochasticDeterminism
        case memoryLifecycle
        case mcpReadiness
        case build
        case consistency
        case complexity
        case overrides
    }

    /// Creates a configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        parallelWorkers = try container.decodeIfPresent(Int.self, forKey: .parallelWorkers)
        excludePatterns = try container.decodeIfPresent([String].self, forKey: .excludePatterns) ?? []
        safetyExemptions = try container.decodeIfPresent([String].self, forKey: .safetyExemptions) ?? ["// SAFETY:"]
        enabledCheckers = try container.decodeIfPresent([String].self, forKey: .enabledCheckers) ?? []
        buildConfiguration = try container.decodeIfPresent(String.self, forKey: .buildConfiguration)
        testFilter = try container.decodeIfPresent(String.self, forKey: .testFilter)
        docTarget = try container.decodeIfPresent(String.self, forKey: .docTarget)
        docCoverageThreshold = try container.decodeIfPresent(Int.self, forKey: .docCoverageThreshold)
        unreachableAutoBuildXcode = try container.decodeIfPresent(Bool.self, forKey: .unreachableAutoBuildXcode) ?? false
        xcodeScheme = try container.decodeIfPresent(String.self, forKey: .xcodeScheme)
        xcodeDestination = try container.decodeIfPresent(String.self, forKey: .xcodeDestination)
        concurrency = try container.decodeIfPresent(ConcurrencyAuditorConfig.self, forKey: .concurrency) ?? .default
        pointerEscape = try container.decodeIfPresent(PointerEscapeAuditorConfig.self, forKey: .pointerEscape) ?? .default
        security = try container.decodeIfPresent(SecurityAuditorConfig.self, forKey: .security) ?? .default
        status = try container.decodeIfPresent(StatusAuditorConfig.self, forKey: .status) ?? .default
        swiftVersion = try container.decodeIfPresent(SwiftVersionConfig.self, forKey: .swiftVersion) ?? .default
        memoryBuilder = try container.decodeIfPresent(MemoryBuilderConfig.self, forKey: .memoryBuilder) ?? .default
        logging = try container.decodeIfPresent(LoggingAuditorConfig.self, forKey: .logging) ?? .default
        dependencyAudit = try container.decodeIfPresent(DependencyAuditorConfig.self, forKey: .dependencyAudit) ?? .default
        releaseReadiness = try container.decodeIfPresent(ReleaseReadinessAuditorConfig.self, forKey: .releaseReadiness) ?? .default
        fpSafety = try container.decodeIfPresent(FloatingPointSafetyAuditorConfig.self, forKey: .fpSafety) ?? .default
        stochasticDeterminism = try container.decodeIfPresent(StochasticDeterminismConfig.self, forKey: .stochasticDeterminism) ?? .default
        memoryLifecycle = try container.decodeIfPresent(MemoryLifecycleConfig.self, forKey: .memoryLifecycle) ?? .default
        mcpReadiness = try container.decodeIfPresent(MCPReadinessConfig.self, forKey: .mcpReadiness) ?? .default
        build = try container.decodeIfPresent(BuildCheckerConfig.self, forKey: .build) ?? .default
        consistency = try container.decodeIfPresent(ConsistencyCheckerConfig.self, forKey: .consistency) ?? .default
        complexity = try container.decodeIfPresent(ComplexityAnalyzerConfig.self, forKey: .complexity) ?? .default
        overrides = try container.decodeIfPresent([String: SeverityOverride].self, forKey: .overrides) ?? [:]
    }
}
