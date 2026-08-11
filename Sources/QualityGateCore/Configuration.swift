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
    public var clusterMatch: Double
    /// Weight for anomaly pattern scoring.
    public var anomalyPattern: Double
    /// Weight for unaddressed policy scoring.
    public var unaddressedPolicy: Double
    /// Weight for recurrence bonus scoring.
    public var recurrenceBonus: Double
    /// Weight for suppression pattern scoring.
    public var suppressionPattern: Double

    /// Default scorer weight configuration.
    public static let defaults = ScorerWeightsConfig(
        clusterMatch: 0.15,
        anomalyPattern: 0.10,
        unaddressedPolicy: 0.05,
        recurrenceBonus: 0.10,
        suppressionPattern: 0.20
    )

    /// Creates a scorer weights configuration with the specified values.
    public init(
        clusterMatch: Double,
        anomalyPattern: Double,
        unaddressedPolicy: Double,
        recurrenceBonus: Double,
        suppressionPattern: Double = 0.20
    ) {
        self.clusterMatch = clusterMatch
        self.anomalyPattern = anomalyPattern
        self.unaddressedPolicy = unaddressedPolicy
        self.recurrenceBonus = recurrenceBonus
        self.suppressionPattern = suppressionPattern
    }
}

/// Per-checker configuration for ConsistencyChecker (IJS).
///
/// ## YAML Example
/// ```yaml
/// consistency:
///   corpusPath: .ijs-corpus
///   projectID: quality-gate-swift
///   useRemoteIdentity: false
///   consistencyThreshold: 0.7
///   defaultRiskTier: 2
///   exemptions: ["Generated/**"]
///   scorerWeights:
///     clusterMatch: 0.15
/// ```
public struct ConsistencyCheckerConfig: Sendable, Equatable {
    /// Path to the IJS corpus directory. nil means IJS is not configured.
    public var corpusPath: String?
    /// Project identifier for the corpus. nil derives from the working directory name.
    public var projectID: String?
    /// Consistency score below this threshold triggers a warning. Default: 0.7.
    public var consistencyThreshold: Double
    /// Default risk tier raw value (1–4) for telemetry metadata. Default: 2 (operational).
    public var defaultRiskTier: Int
    /// Custom scorer weights. nil uses ScorerWeights.defaults.
    public var scorerWeights: ScorerWeightsConfig?
    /// Module or path patterns exempt from consistency checks.
    public var exemptions: [String]
    /// Derive the corpus projectID from the normalized git remote instead of
    /// the directory basename (Phase 0.4). Default false for one release so
    /// portfolios migrate deliberately via `migrate-corpus-identity`.
    public var useRemoteIdentity: Bool

    /// Creates a consistency checker configuration with the specified values.
    public init(
        corpusPath: String? = nil,
        projectID: String? = nil,
        consistencyThreshold: Double = 0.7,
        defaultRiskTier: Int = 2,
        scorerWeights: ScorerWeightsConfig? = nil,
        exemptions: [String] = [],
        useRemoteIdentity: Bool = false
    ) {
        self.corpusPath = corpusPath
        self.projectID = projectID
        self.consistencyThreshold = consistencyThreshold
        self.defaultRiskTier = defaultRiskTier
        self.scorerWeights = scorerWeights
        self.exemptions = exemptions
        self.useRemoteIdentity = useRemoteIdentity
    }

    /// Default consistency checker configuration.
    public static let `default` = ConsistencyCheckerConfig()
}

extension ConsistencyCheckerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case corpusPath, projectID, consistencyThreshold, defaultRiskTier, scorerWeights, exemptions, useRemoteIdentity
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
        useRemoteIdentity = try container.decodeIfPresent(Bool.self, forKey: .useRemoteIdentity) ?? defaults.useRemoteIdentity
    }
}

/// Per-checker configuration for ConcurrencyAuditor.
public struct ConcurrencyAuditorConfig: Sendable, Equatable {
    /// Comment keyword that suppresses unchecked-Sendable / nonisolated-unsafe rules.
    public var justificationKeyword: String
    /// Module names that are allowed to keep `@preconcurrency import` even if first-party.
    public var allowPreconcurrencyImports: [String]
    /// Whether to run the optional Pass 2 using IndexStoreDB for cross-file Sendable validation.
    public var useIndexStore: Bool
    /// Whether to enable isolation-depth tracking for the `sendable-crosses-isolation` rule.
    /// Off by default for performance.
    public var trackIsolationDepth: Bool
    /// Whether the `cancellation-checkpoint-after-loop` rule emits `.error` (strict)
    /// instead of the default `.warning`. Off by default for incremental adoption.
    public var cancellationCheckpointStrict: Bool

    /// Creates a concurrency auditor configuration with the given options.
    public init(
        justificationKeyword: String = "Justification:",
        allowPreconcurrencyImports: [String] = [],
        useIndexStore: Bool = true,
        trackIsolationDepth: Bool = false,
        cancellationCheckpointStrict: Bool = false
    ) {
        self.justificationKeyword = justificationKeyword
        self.allowPreconcurrencyImports = allowPreconcurrencyImports
        self.useIndexStore = useIndexStore
        self.trackIsolationDepth = trackIsolationDepth
        self.cancellationCheckpointStrict = cancellationCheckpointStrict
    }

    /// Default concurrency auditor configuration.
    public static let `default` = ConcurrencyAuditorConfig()
}

extension ConcurrencyAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case justificationKeyword, allowPreconcurrencyImports, useIndexStore, trackIsolationDepth, cancellationCheckpointStrict
    }

    /// Creates a concurrency auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ConcurrencyAuditorConfig.default
        justificationKeyword = try container.decodeIfPresent(String.self, forKey: .justificationKeyword) ?? defaults.justificationKeyword
        allowPreconcurrencyImports = try container.decodeIfPresent([String].self, forKey: .allowPreconcurrencyImports) ?? defaults.allowPreconcurrencyImports
        useIndexStore = try container.decodeIfPresent(Bool.self, forKey: .useIndexStore) ?? defaults.useIndexStore
        trackIsolationDepth = try container.decodeIfPresent(Bool.self, forKey: .trackIsolationDepth) ?? defaults.trackIsolationDepth
        cancellationCheckpointStrict = try container.decodeIfPresent(Bool.self, forKey: .cancellationCheckpointStrict) ?? defaults.cancellationCheckpointStrict
    }
}

/// Per-checker configuration for PointerEscapeAuditor.
public struct PointerEscapeAuditorConfig: Sendable, Equatable {
    /// Function names allowed to receive a borrowed pointer (escape suppression).
    public var allowedEscapeFunctions: [String]

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
    public var enabledRules: [String]

    /// Regex patterns for variable names that indicate secrets.
    public var secretPatterns: [String]

    /// Hosts allowed to use http:// (e.g. localhost test servers).
    public var allowedHTTPHosts: [String]

    /// SQL-executing function names that trigger the sql-injection rule.
    public var sqlFunctionNames: [String]

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
    public var guidelinesPath: String

    /// Path to Master Plan relative to the guidelines directory.
    public var masterPlanPath: String

    /// Minimum source lines to consider a module "implemented" (not a stub).
    public var stubThresholdLines: Int

    /// Maximum allowed percentage difference between documented and actual test counts.
    public var testCountDriftPercent: Int

    /// Maximum days since "Last Updated" before flagging staleness.
    public var lastUpdatedStaleDays: Int

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
    public var minimum: String

    /// Whether to also check and report the local compiler version.
    public var checkCompiler: Bool

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
    public var guidelinesPath: String

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
///   allowedSilentTryFunctions: ["Task.sleep", "JSONEncoder", "JSONDecoder", "checkResourceIsReachable", ...]
///   customLoggerNames: ["HarborLog", "WatchLog"]
/// ```
public struct LoggingAuditorConfig: Sendable, Equatable {
    /// Project type: "application" enables all rules, "cli" skips print-statement and no-os-logger-import, "library" skips the auditor entirely.
    public var projectType: String

    /// Comment keyword that suppresses silent-try warnings.
    public var silentTryKeyword: String

    /// Function names where `try?` is considered safe (fire-and-forget patterns).
    public var allowedSilentTryFunctions: [String]

    /// Additional logger type names beyond os.Logger (e.g. project-specific wrappers).
    public var customLoggerNames: [String]

    /// Creates a logging auditor configuration with the given options.
    public init(
        projectType: String = "application",
        silentTryKeyword: String = "silent:",
        allowedSilentTryFunctions: [String] = [
            "Task.sleep", "JSONEncoder", "JSONDecoder",
            "checkResourceIsReachable", "resourceValues(forKeys:",
            "container.decode(", "singleValueContainer()",
            "removeItem(at", "removeItem(atPath",
            ".close()",
        ],
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
    public var maxMajorVersionsBehind: Int

    /// Branch pins that are explicitly allowed.
    public var allowBranchPins: [String]

    /// Skip network calls to check latest tags.
    public var offlineMode: Bool

    /// Additional module names to treat as valid (e.g., Xcode-only targets, bridging modules).
    public var additionalKnownModules: [String]

    /// Creates a dependency auditor configuration with the given options.
    public init(
        maxMajorVersionsBehind: Int = 2,
        allowBranchPins: [String] = [],
        offlineMode: Bool = false,
        additionalKnownModules: [String] = []
    ) {
        self.maxMajorVersionsBehind = maxMajorVersionsBehind
        self.allowBranchPins = allowBranchPins
        self.offlineMode = offlineMode
        self.additionalKnownModules = additionalKnownModules
    }

    /// Default dependency auditor configuration.
    public static let `default` = DependencyAuditorConfig()
}

extension DependencyAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case maxMajorVersionsBehind, allowBranchPins, offlineMode, additionalKnownModules
    }

    /// Creates a dependency auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DependencyAuditorConfig.default
        maxMajorVersionsBehind = try container.decodeIfPresent(Int.self, forKey: .maxMajorVersionsBehind) ?? defaults.maxMajorVersionsBehind
        allowBranchPins = try container.decodeIfPresent([String].self, forKey: .allowBranchPins) ?? defaults.allowBranchPins
        offlineMode = try container.decodeIfPresent(Bool.self, forKey: .offlineMode) ?? defaults.offlineMode
        additionalKnownModules = try container.decodeIfPresent([String].self, forKey: .additionalKnownModules) ?? defaults.additionalKnownModules
    }
}

/// Per-checker configuration for SubmoduleAuditor.
public struct SubmoduleAuditorConfig: Sendable, Equatable, Codable {
    /// Package checkout names to skip (e.g. third-party packages with public submodules).
    public var allowedPackages: [String]

    /// Creates a submodule auditor configuration.
    public init(allowedPackages: [String] = []) {
        self.allowedPackages = allowedPackages
    }

    /// Default submodule auditor configuration.
    public static let `default` = SubmoduleAuditorConfig()

    private enum CodingKeys: String, CodingKey {
        case allowedPackages
    }

    /// Creates a submodule auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowedPackages = try container.decodeIfPresent([String].self, forKey: .allowedPackages) ?? []
    }
}

/// Per-checker configuration for ReleaseReadinessAuditor.
public struct ReleaseReadinessAuditorConfig: Sendable, Equatable {
    /// Path to CHANGELOG file relative to project root.
    public var changelogPath: String

    /// Path to README file relative to project root.
    public var readmePath: String

    /// Whether TODO/FIXME in source files require issue references.
    public var requireIssueReference: Bool

    /// Additional marker patterns to flag beyond TODO/FIXME/HACK/XXX.
    public var additionalMarkers: [String]

    /// Whether to error when the latest CHANGELOG version has no matching git tag.
    public var checkVersionTagParity: Bool

    /// Whether to error when a README-advertised dependency version has no matching git tag.
    public var checkDependencyResolvability: Bool

    /// Creates a release readiness auditor configuration with the given options.
    public init(
        changelogPath: String = "CHANGELOG.md",
        readmePath: String = "README.md",
        requireIssueReference: Bool = false,
        additionalMarkers: [String] = [],
        checkVersionTagParity: Bool = true,
        checkDependencyResolvability: Bool = true
    ) {
        self.changelogPath = changelogPath
        self.readmePath = readmePath
        self.requireIssueReference = requireIssueReference
        self.additionalMarkers = additionalMarkers
        self.checkVersionTagParity = checkVersionTagParity
        self.checkDependencyResolvability = checkDependencyResolvability
    }

    /// Default release readiness auditor configuration.
    public static let `default` = ReleaseReadinessAuditorConfig()
}

extension ReleaseReadinessAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case changelogPath, readmePath, requireIssueReference, additionalMarkers
        case checkVersionTagParity, checkDependencyResolvability
    }

    /// Creates a release readiness auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReleaseReadinessAuditorConfig.default
        changelogPath = try container.decodeIfPresent(String.self, forKey: .changelogPath) ?? defaults.changelogPath
        readmePath = try container.decodeIfPresent(String.self, forKey: .readmePath) ?? defaults.readmePath
        requireIssueReference = try container.decodeIfPresent(Bool.self, forKey: .requireIssueReference) ?? defaults.requireIssueReference
        additionalMarkers = try container.decodeIfPresent([String].self, forKey: .additionalMarkers) ?? defaults.additionalMarkers
        checkVersionTagParity = try container.decodeIfPresent(Bool.self, forKey: .checkVersionTagParity) ?? defaults.checkVersionTagParity
        checkDependencyResolvability = try container.decodeIfPresent(Bool.self, forKey: .checkDependencyResolvability) ?? defaults.checkDependencyResolvability
    }
}

/// Per-checker configuration for FloatingPointSafetyAuditor.
public struct FloatingPointSafetyAuditorConfig: Sendable, Equatable {
    /// Files to exclude from FP safety checks.
    public var allowedFiles: [String]

    /// Whether to check for unguarded division.
    public var checkDivisionGuards: Bool

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
    public var exemptFunctions: [String]

    /// Files exempt from stochastic checks.
    public var exemptFiles: [String]

    /// Whether to flag collection `.shuffled()` without `using:` parameter.
    public var flagCollectionShuffle: Bool

    /// Whether to flag global C-style random state (`drand48`, `arc4random`).
    public var flagGlobalState: Bool

    /// Whether `Tests/` is walked at all.
    ///
    /// A test is as capable of being non-deterministic as anything in `Sources/`, and the
    /// rules that fire there are the ones no other checker implements — see
    /// ``StochasticDeterminismAuditor`` for the division of labour with `test-quality`.
    public var auditTests: Bool

    /// Whether to flag a test call that omits a defaulted `seed:` argument
    /// (`stochastic-unseeded-test-call`). Requires `auditTests`.
    public var flagUnseededTestCalls: Bool

    /// Creates a stochastic determinism configuration with the given options.
    public init(
        exemptFunctions: [String] = [],
        exemptFiles: [String] = [],
        flagCollectionShuffle: Bool = true,
        flagGlobalState: Bool = true,
        auditTests: Bool = true,
        flagUnseededTestCalls: Bool = true
    ) {
        self.exemptFunctions = exemptFunctions
        self.exemptFiles = exemptFiles
        self.flagCollectionShuffle = flagCollectionShuffle
        self.flagGlobalState = flagGlobalState
        self.auditTests = auditTests
        self.flagUnseededTestCalls = flagUnseededTestCalls
    }

    /// Default stochastic determinism configuration.
    public static let `default` = StochasticDeterminismConfig()
}

extension StochasticDeterminismConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case exemptFunctions, exemptFiles, flagCollectionShuffle, flagGlobalState, auditTests
        case flagUnseededTestCalls
    }

    /// Creates a stochastic determinism configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StochasticDeterminismConfig.default
        exemptFunctions = try container.decodeIfPresent([String].self, forKey: .exemptFunctions) ?? defaults.exemptFunctions
        exemptFiles = try container.decodeIfPresent([String].self, forKey: .exemptFiles) ?? defaults.exemptFiles
        flagCollectionShuffle = try container.decodeIfPresent(Bool.self, forKey: .flagCollectionShuffle) ?? defaults.flagCollectionShuffle
        flagGlobalState = try container.decodeIfPresent(Bool.self, forKey: .flagGlobalState) ?? defaults.flagGlobalState
        auditTests = try container.decodeIfPresent(Bool.self, forKey: .auditTests) ?? defaults.auditTests
        flagUnseededTestCalls = try container.decodeIfPresent(Bool.self, forKey: .flagUnseededTestCalls) ?? defaults.flagUnseededTestCalls
    }
}

// TemporalDeterminismConfig moved to VigilKit (Phase 4 extraction);
// re-exported through QualityGateCore so `configuration.temporalDeterminism`
// keeps its type unchanged.

/// Configuration for the test-outcome flip detector (within TestRunner).
///
/// The detector persists a per-package roster after each `test` run and flags any test
/// whose pass/fail outcome flips while the package fingerprint is unchanged — i.e.
/// scheduler-dependent behavior. See ``FlipDetector``.
public struct FlipDetectorConfig: Sendable, Equatable, Codable {
    /// Whether flip detection runs after the test suite. On by default.
    public var enabled: Bool

    /// When true, a detected flip is an `.error` (fails the gate) instead of a `.warning`.
    public var strict: Bool

    /// Creates a flip-detector configuration with the given options.
    public init(enabled: Bool = true, strict: Bool = false) {
        self.enabled = enabled
        self.strict = strict
    }

    /// Default flip-detector configuration.
    public static let `default` = FlipDetectorConfig()

    private enum CodingKeys: String, CodingKey {
        case enabled, strict
    }

    /// Creates a flip-detector configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FlipDetectorConfig.default
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        strict = try container.decodeIfPresent(Bool.self, forKey: .strict) ?? defaults.strict
    }
}

/// Configuration for deliberate stress runs of timing-tagged tests (within TestRunner).
///
/// Tests carrying the `marker` comment (default `// TIMING:`) are self-identifying
/// stress candidates — teardown-liveness bounds, reconnect budgets, phase-sync. When
/// `runs > 1`, TestRunner re-runs *only* those tests `runs` times (optionally under a
/// CPU-contention harness) to compress the scheduler window; any test that does not
/// return the same outcome across all runs is a definitive race. Meant for
/// per-release / nightly cadence, not per-commit — `runs == 1` is a no-op.
public struct StressTestConfig: Sendable, Equatable, Codable {
    /// Number of times to re-run each timing-tagged test. `1` disables stress mode.
    public var runs: Int

    /// Whether to run the repetitions under background CPU contention (best-effort).
    public var contention: Bool

    /// When true, an intra-batch flip is an `.error` instead of a `.warning`.
    public var strict: Bool

    /// Comment marker that identifies a timing-sensitive test.
    public var marker: String

    /// Creates a stress-test configuration with the given options.
    public init(runs: Int = 1, contention: Bool = false, strict: Bool = false, marker: String = "// TIMING:") {
        self.runs = runs
        self.contention = contention
        self.strict = strict
        self.marker = marker
    }

    /// Default stress-test configuration (disabled).
    public static let `default` = StressTestConfig()

    private enum CodingKeys: String, CodingKey {
        case runs, contention, strict, marker
    }

    /// Creates a stress-test configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StressTestConfig.default
        runs = try container.decodeIfPresent(Int.self, forKey: .runs) ?? defaults.runs
        contention = try container.decodeIfPresent(Bool.self, forKey: .contention) ?? defaults.contention
        strict = try container.decodeIfPresent(Bool.self, forKey: .strict) ?? defaults.strict
        marker = try container.decodeIfPresent(String.self, forKey: .marker) ?? defaults.marker
    }
}

/// Per-checker configuration for MemoryLifecycleGuard.
public struct MemoryLifecycleConfig: Sendable, Equatable {
    /// Property name patterns that indicate delegate/parent references.
    public var delegatePatterns: [String]

    /// Whether to require Task cancellation in deinit.
    public var requireTaskCancellation: Bool

    /// Files exempt from lifecycle checks.
    public var exemptFiles: [String]

    /// Type names whose construction inside loops requires autoreleasepool.
    public var heavyFrameworkTypes: [String]

    /// File patterns exempt from the loop-growth rule.
    public var loopGrowthExemptPatterns: [String]

    /// Whether to run the optional Pass 2 using IndexStoreDB for cross-file lifecycle validation.
    public var useIndexStore: Bool

    /// Creates a memory lifecycle configuration with the given options.
    public init(
        delegatePatterns: [String] = ["delegate", "parent", "owner", "dataSource"],
        requireTaskCancellation: Bool = true,
        exemptFiles: [String] = [],
        heavyFrameworkTypes: [String] = [
            "MLXArray", "MTLBuffer", "MTLTexture",
            "CGImage", "CGContext", "CVPixelBuffer"
        ],
        loopGrowthExemptPatterns: [String] = [],
        useIndexStore: Bool = true
    ) {
        self.delegatePatterns = delegatePatterns
        self.requireTaskCancellation = requireTaskCancellation
        self.exemptFiles = exemptFiles
        self.heavyFrameworkTypes = heavyFrameworkTypes
        self.loopGrowthExemptPatterns = loopGrowthExemptPatterns
        self.useIndexStore = useIndexStore
    }

    /// Default memory lifecycle configuration.
    public static let `default` = MemoryLifecycleConfig()
}

extension MemoryLifecycleConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case delegatePatterns, requireTaskCancellation, exemptFiles
        case heavyFrameworkTypes, loopGrowthExemptPatterns, useIndexStore
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
        useIndexStore = try container.decodeIfPresent(Bool.self, forKey: .useIndexStore) ?? defaults.useIndexStore
    }
}

/// Per-checker configuration for MCPReadinessAuditor.
public struct MCPReadinessConfig: Sendable, Equatable {
    /// Whether the MCP readiness checker is enabled.
    public var enabled: Bool

    /// Minimum character length for tool and property descriptions.
    public var minDescriptionLength: Int

    /// Additional source directories to scan for MCP tools.
    public var additionalPaths: [String]

    /// Source directories to exclude from scanning.
    public var excludePaths: [String]

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

/// Per-checker configuration for AppIntentsAuditor.
public struct AppIntentsReadinessConfig: Sendable, Equatable {
    /// Whether the App Intents readiness checker is enabled.
    public var enabled: Bool

    /// Minimum character length for intent and parameter descriptions.
    public var minDescriptionLength: Int

    /// Source directories to exclude from scanning.
    public var excludePaths: [String]

    /// Whether to require AppShortcutsProvider when intents exist.
    public var requireShortcutsProvider: Bool

    /// Whether to audit AppEntity conformances for queries and display.
    public var auditEntities: Bool

    /// Whether to audit AppEnum conformances for display and assistant annotations.
    public var auditEnums: Bool

    /// Whether to use IndexStoreDB for cross-file conformance resolution.
    public var useIndexStore: Bool

    /// Creates an App Intents readiness configuration with the given options.
    public init(
        enabled: Bool = false,
        minDescriptionLength: Int = 10,
        excludePaths: [String] = [],
        requireShortcutsProvider: Bool = true,
        auditEntities: Bool = true,
        auditEnums: Bool = true,
        useIndexStore: Bool = true
    ) {
        self.enabled = enabled
        self.minDescriptionLength = minDescriptionLength
        self.excludePaths = excludePaths
        self.requireShortcutsProvider = requireShortcutsProvider
        self.auditEntities = auditEntities
        self.auditEnums = auditEnums
        self.useIndexStore = useIndexStore
    }

    /// Default App Intents readiness configuration.
    public static let `default` = AppIntentsReadinessConfig()
}

extension AppIntentsReadinessConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case enabled, minDescriptionLength, excludePaths
        case requireShortcutsProvider, auditEntities, auditEnums, useIndexStore
    }

    /// Creates an App Intents readiness configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppIntentsReadinessConfig.default
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        minDescriptionLength = try container.decodeIfPresent(Int.self, forKey: .minDescriptionLength) ?? defaults.minDescriptionLength
        excludePaths = try container.decodeIfPresent([String].self, forKey: .excludePaths) ?? defaults.excludePaths
        requireShortcutsProvider = try container.decodeIfPresent(Bool.self, forKey: .requireShortcutsProvider) ?? defaults.requireShortcutsProvider
        auditEntities = try container.decodeIfPresent(Bool.self, forKey: .auditEntities) ?? defaults.auditEntities
        auditEnums = try container.decodeIfPresent(Bool.self, forKey: .auditEnums) ?? defaults.auditEnums
        useIndexStore = try container.decodeIfPresent(Bool.self, forKey: .useIndexStore) ?? defaults.useIndexStore
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
    public var pattern: String
    /// The known Big-O cost (e.g., "O(n)", "O(1)", "O(n log n)").
    public var cost: String

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
    public var cognitiveThreshold: Int

    /// Number of top-complexity functions to include in reports.
    public var reportTopN: Int

    /// Per-module threshold overrides (module name to threshold).
    public var moduleThresholds: [String: Int]

    /// Whether to emit complexity data to the IJS corpus.
    public var emitToCorpus: Bool

    /// Whether to enable call-graph amplification (cross-function cost composition).
    public var callGraphEnabled: Bool

    /// Maximum transitive depth for call-graph amplification (1 = direct calls only).
    public var callGraphMaxDepth: Int

    /// User-declared function costs for project-specific or third-party operations.
    public var knownCosts: [KnownCostEntry]

    /// Whether to run the optional Pass 2 using IndexStoreDB for cross-module complexity resolution.
    public var useIndexStore: Bool

    /// Whether to enable cross-module cognitive complexity amplification in Pass 2.
    public var crossModuleAmplification: Bool

    /// Maximum transitive depth for cross-module amplification (1 = direct cross-module calls only).
    public var crossModuleMaxDepth: Int

    /// Amplified cognitive complexity threshold for cross-module warnings.
    public var amplifiedCognitiveThreshold: Int

    /// Creates a complexity analyzer configuration with the given options.
    public init(
        cognitiveThreshold: Int = 15,
        reportTopN: Int = 10,
        moduleThresholds: [String: Int] = [:],
        emitToCorpus: Bool = true,
        callGraphEnabled: Bool = true,
        callGraphMaxDepth: Int = 1,
        knownCosts: [KnownCostEntry] = [],
        useIndexStore: Bool = true,
        crossModuleAmplification: Bool = true,
        crossModuleMaxDepth: Int = 1,
        amplifiedCognitiveThreshold: Int = 30
    ) {
        self.cognitiveThreshold = cognitiveThreshold
        self.reportTopN = reportTopN
        self.moduleThresholds = moduleThresholds
        self.emitToCorpus = emitToCorpus
        self.callGraphEnabled = callGraphEnabled
        self.callGraphMaxDepth = callGraphMaxDepth
        self.knownCosts = knownCosts
        self.useIndexStore = useIndexStore
        self.crossModuleAmplification = crossModuleAmplification
        self.crossModuleMaxDepth = crossModuleMaxDepth
        self.amplifiedCognitiveThreshold = amplifiedCognitiveThreshold
    }

    /// Default complexity analyzer configuration.
    public static let `default` = ComplexityAnalyzerConfig()
}

extension ComplexityAnalyzerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case cognitiveThreshold, reportTopN, moduleThresholds, emitToCorpus
        case callGraphEnabled, callGraphMaxDepth, knownCosts
        case useIndexStore, crossModuleAmplification, crossModuleMaxDepth, amplifiedCognitiveThreshold
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
        useIndexStore = try container.decodeIfPresent(Bool.self, forKey: .useIndexStore) ?? defaults.useIndexStore
        crossModuleAmplification = try container.decodeIfPresent(Bool.self, forKey: .crossModuleAmplification) ?? defaults.crossModuleAmplification
        crossModuleMaxDepth = try container.decodeIfPresent(Int.self, forKey: .crossModuleMaxDepth) ?? defaults.crossModuleMaxDepth
        amplifiedCognitiveThreshold = try container.decodeIfPresent(Int.self, forKey: .amplifiedCognitiveThreshold) ?? defaults.amplifiedCognitiveThreshold
    }
}

/// Per-checker configuration for LegibilityAnalyzer (advisory).
///
/// The LegibilityAnalyzer reports on whole-codebase *navigability* — module
/// centrality, orientation, cycles, and apparent public surface. It never gates;
/// all findings are advisory notes. See the design proposal at
/// `development-guidelines/02_IMPLEMENTATION_PLANS/PROPOSALS/LegibilityAnalyzer.md`.
///
/// ## YAML Example
/// ```yaml
/// legibility:
///   minFanInForCentral: 3
///   centralUnorientedTopN: 10
///   exemptSymbols:
///     - "MyKit.reservedForDownstream"
/// ```
public struct LegibilityAnalyzerConfig: Sendable, Equatable {
    /// Whether to run the optional IndexStore pass for the semantic module graph.
    /// When false (or when no fresh index exists) the analyzer falls back to the
    /// declared `Package.swift` dependency graph and skips per-symbol rules.
    public var useIndexStore: Bool

    /// Number of highest-ranked central-but-unoriented modules to report.
    public var centralUnorientedTopN: Int

    /// Minimum fan-in for a module to be considered "load-bearing" (central).
    public var minFanInForCentral: Int

    /// Whether to flag live `public` symbols referenced only within their module.
    public var flagOverPublicSymbols: Bool

    /// Whether to flag dependency cycles between modules.
    public var flagCycles: Bool

    /// Whether to emit the reading-order / module-map documentation artifact.
    public var emitReadingOrderArtifact: Bool

    /// Where the JSON/Markdown map artifact is written (nil → default location).
    public var artifactPath: String?

    /// Modules excluded from all legibility rules (e.g. generated targets).
    public var exemptModules: Set<String>

    /// Over-public symbols acknowledged out of band (fully-qualified names).
    public var exemptSymbols: Set<String>

    /// Inline marker that acknowledges an intentional over-public symbol.
    public var reservedMarker: String

    /// Whether to emit per-module orientation cards to the IJS corpus (consumed by
    /// the dashboard's module-orientation section). Only takes effect when a
    /// corpus path is configured.
    public var emitToCorpus: Bool

    /// Creates a legibility analyzer configuration with the given options.
    public init(
        useIndexStore: Bool = true,
        centralUnorientedTopN: Int = 10,
        minFanInForCentral: Int = 3,
        flagOverPublicSymbols: Bool = true,
        flagCycles: Bool = true,
        emitReadingOrderArtifact: Bool = true,
        artifactPath: String? = nil,
        exemptModules: Set<String> = [],
        exemptSymbols: Set<String> = [],
        reservedMarker: String = "legibility:reserved",
        emitToCorpus: Bool = true
    ) {
        self.useIndexStore = useIndexStore
        self.centralUnorientedTopN = centralUnorientedTopN
        self.minFanInForCentral = minFanInForCentral
        self.flagOverPublicSymbols = flagOverPublicSymbols
        self.flagCycles = flagCycles
        self.emitReadingOrderArtifact = emitReadingOrderArtifact
        self.artifactPath = artifactPath
        self.exemptModules = exemptModules
        self.exemptSymbols = exemptSymbols
        self.reservedMarker = reservedMarker
        self.emitToCorpus = emitToCorpus
    }

    /// Default legibility analyzer configuration.
    public static let `default` = LegibilityAnalyzerConfig()
}

extension LegibilityAnalyzerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case useIndexStore, centralUnorientedTopN, minFanInForCentral
        case flagOverPublicSymbols, flagCycles, emitReadingOrderArtifact
        case artifactPath, exemptModules, exemptSymbols, reservedMarker, emitToCorpus
    }

    /// Creates a legibility analyzer configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LegibilityAnalyzerConfig.default
        useIndexStore = try container.decodeIfPresent(Bool.self, forKey: .useIndexStore) ?? defaults.useIndexStore
        centralUnorientedTopN = try container.decodeIfPresent(Int.self, forKey: .centralUnorientedTopN) ?? defaults.centralUnorientedTopN
        minFanInForCentral = try container.decodeIfPresent(Int.self, forKey: .minFanInForCentral) ?? defaults.minFanInForCentral
        flagOverPublicSymbols = try container.decodeIfPresent(Bool.self, forKey: .flagOverPublicSymbols) ?? defaults.flagOverPublicSymbols
        flagCycles = try container.decodeIfPresent(Bool.self, forKey: .flagCycles) ?? defaults.flagCycles
        emitReadingOrderArtifact = try container.decodeIfPresent(Bool.self, forKey: .emitReadingOrderArtifact) ?? defaults.emitReadingOrderArtifact
        artifactPath = try container.decodeIfPresent(String.self, forKey: .artifactPath) ?? defaults.artifactPath
        exemptModules = try container.decodeIfPresent(Set<String>.self, forKey: .exemptModules) ?? defaults.exemptModules
        exemptSymbols = try container.decodeIfPresent(Set<String>.self, forKey: .exemptSymbols) ?? defaults.exemptSymbols
        reservedMarker = try container.decodeIfPresent(String.self, forKey: .reservedMarker) ?? defaults.reservedMarker
        emitToCorpus = try container.decodeIfPresent(Bool.self, forKey: .emitToCorpus) ?? defaults.emitToCorpus
    }
}

/// Per-checker configuration for XcodeBuildChecker.
///
/// Drives `xcodebuild build` for one or more simulator destinations,
/// catching cross-platform errors invisible to `swift build` (macOS only).
///
/// ## YAML Example
/// ```yaml
/// xcodeBuild:
///   project: MyApp.xcodeproj
///   scheme: MyApp
///   destinations:
///     - "platform=iOS Simulator,name=iPhone 17 Pro"
/// ```
public struct XcodeBuildCheckerConfig: Sendable, Equatable {
    /// Path to `.xcodeproj` (relative to project root).
    public var project: String?

    /// Path to `.xcworkspace` (takes precedence over `project`).
    public var workspace: String?

    /// Xcode scheme to build. nil auto-detects the first scheme.
    public var scheme: String?

    /// Simulator destinations to build for. Empty uses `generic/platform=macOS`.
    public var destinations: [String]

    /// Creates an Xcode build checker configuration with the given options.
    public init(
        project: String? = nil,
        workspace: String? = nil,
        scheme: String? = nil,
        destinations: [String] = []
    ) {
        self.project = project
        self.workspace = workspace
        self.scheme = scheme
        self.destinations = destinations
    }

    /// Default Xcode build checker configuration.
    public static let `default` = XcodeBuildCheckerConfig()
}

extension XcodeBuildCheckerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case project, workspace, scheme, destinations
    }

    /// Creates an Xcode build checker configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = XcodeBuildCheckerConfig.default
        project = try container.decodeIfPresent(String.self, forKey: .project) ?? defaults.project
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace) ?? defaults.workspace
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme) ?? defaults.scheme
        destinations = try container.decodeIfPresent([String].self, forKey: .destinations) ?? defaults.destinations
    }
}

/// Per-checker configuration for RecursionAuditor.
///
/// Controls whether the IndexStoreDB-backed Pass 2 (USR-based call graph)
/// is used to validate mutual-cycle findings from the syntactic Pass 1.
public struct RecursionAuditorConfig: Sendable, Equatable {
    /// Whether to use IndexStoreDB for USR-based call graph resolution.
    public var useIndexStore: Bool

    /// Creates a recursion auditor configuration with the given options.
    public init(useIndexStore: Bool = true) {
        self.useIndexStore = useIndexStore
    }

    /// Default recursion auditor configuration.
    public static let `default` = RecursionAuditorConfig()
}

extension RecursionAuditorConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case useIndexStore
    }

    /// Creates a recursion auditor configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useIndexStore = try container.decodeIfPresent(Bool.self, forKey: .useIndexStore) ?? RecursionAuditorConfig.default.useIndexStore
    }
}

/// Per-checker configuration for DocCoverageChecker.
///
/// Controls whether the IndexStoreDB-backed Pass 2 runs to detect
/// inherited documentation from protocol requirements and rank
/// undocumented APIs by usage frequency.
///
/// ## YAML Example
/// ```yaml
/// docCoverage:
///   useIndexStore: true
///   includeTestReferences: false
/// ```
public struct DocCoverageConfig: Sendable, Codable, Equatable {
    /// Whether to run the optional Pass 2 using IndexStoreDB for inherited-doc detection and usage-priority ranking.
    public var useIndexStore: Bool

    /// Whether to include references from test targets when computing usage-priority rankings.
    public var includeTestReferences: Bool

    /// Creates a documentation coverage configuration with the given options.
    public init(
        useIndexStore: Bool = true,
        includeTestReferences: Bool = false
    ) {
        self.useIndexStore = useIndexStore
        self.includeTestReferences = includeTestReferences
    }

    /// Default documentation coverage configuration.
    public static let `default` = DocCoverageConfig()
}

extension DocCoverageConfig {
    private enum CodingKeys: String, CodingKey {
        case useIndexStore, includeTestReferences
    }

    /// Creates a documentation coverage configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DocCoverageConfig.default
        useIndexStore = try container.decodeIfPresent(Bool.self, forKey: .useIndexStore) ?? defaults.useIndexStore
        includeTestReferences = try container.decodeIfPresent(Bool.self, forKey: .includeTestReferences) ?? defaults.includeTestReferences
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
    public var solverExpressionTimeThreshold: Int?

    /// Whether to compile the test target as well as the library, via `--build-tests`.
    ///
    /// Defaults to `true`, because the alternative is a blind spot rather than a
    /// saving. Plain `swift build` compiles only the library, so every diagnostic in
    /// the test target is invisible here — and the test checker compiles those same
    /// files moments later and discards their warnings in favour of test results.
    /// Nothing looks at them, and a project can report zero warnings with a test
    /// target full of them, including deprecation warnings on functions the library
    /// itself documents as incorrect.
    ///
    /// It is also close to free where the test checker runs: that compilation is
    /// happening either way, so this changes what is read, not what is built.
    ///
    /// Set to `false` for a package whose tests are mid-migration and expected not to
    /// compile, where a red build would drown the signal from the library. Prefer
    /// fixing the tests.
    public var includeTests: Bool

    /// Creates a build checker configuration with the given options.
    public init(solverExpressionTimeThreshold: Int? = nil, includeTests: Bool = true) {
        self.solverExpressionTimeThreshold = solverExpressionTimeThreshold
        self.includeTests = includeTests
    }

    /// Default build checker configuration: no threshold, test target included.
    public static let `default` = BuildCheckerConfig()
}

extension BuildCheckerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case solverExpressionTimeThreshold
        case includeTests
    }

    /// Creates a build checker configuration by decoding from the given decoder.
    ///
    /// An absent `includeTests` key decodes to `true`, so a configuration file written
    /// before this option existed gains test-target coverage rather than silently
    /// keeping the old blind spot.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        solverExpressionTimeThreshold = try container.decodeIfPresent(Int.self, forKey: .solverExpressionTimeThreshold)
        includeTests = try container.decodeIfPresent(Bool.self, forKey: .includeTests) ?? true
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


/// One Tier-2 executable plugin (Phase 4b): any binary speaking the
/// quality-gate plugin contract (JSON over stdio).
///
/// Advisory by default — `gates: true` is an explicit, per-plugin decision.
/// The plugin's `config:` block is passed through verbatim, uninterpreted.
public struct PluginConfig: Sendable, Equatable, Codable {
    /// Display / origin-tag name (also the checker id in reports).
    public var name: String
    /// Executable path. Nil discovers `quality-gate-plugin-<name>` on PATH.
    public var run: String?
    /// Whether this plugin's findings may gate. Default false (advisory).
    public var gates: Bool
    /// Verbatim configuration forwarded in the check request.
    public var config: JSONValue?
    /// Wall-clock budget for one check invocation, in seconds.
    public var timeoutSeconds: Int

    /// Creates a plugin entry.
    public init(
        name: String,
        run: String? = nil,
        gates: Bool = false,
        config: JSONValue? = nil,
        timeoutSeconds: Int = 60
    ) {
        self.name = name
        self.run = run
        self.gates = gates
        self.config = config
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case name, run, gates, config, timeoutSeconds
    }

    /// Decodes with defaults for absent optional keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        run = try container.decodeIfPresent(String.self, forKey: .run)
        gates = try container.decodeIfPresent(Bool.self, forKey: .gates) ?? false
        config = try container.decodeIfPresent(JSONValue.self, forKey: .config)
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
    }
}

/// One Tier-1 declarative custom rule (Phase 4b): a line regex declared in
/// `.quality-gate.yml`, no code required — SwiftLint `custom_rules` parity.
///
/// Custom rules are the user's own policy, so gating is theirs to declare:
/// the configured `severity` is exactly what gates (`error` fails the run).
/// Findings report under the rule's `id` with `origin: custom-rule`.
public struct CustomRuleConfig: Sendable, Equatable, Codable {
    /// Rule identifier — the `ruleId` on every finding (e.g. `house.no-print`).
    public var id: String
    /// Line regex (NSRegularExpression syntax) that constitutes a violation.
    public var pattern: String
    /// Path globs the rule applies to. Empty means every Swift source.
    public var include: [String]
    /// Path globs the rule never applies to. Exclude wins over include.
    public var exclude: [String]
    /// The message shown for each finding.
    public var message: String
    /// Declared severity — and therefore gating. Default `warning`.
    public var severity: Diagnostic.Severity

    /// Creates a custom rule entry.
    public init(
        id: String,
        pattern: String,
        include: [String] = [],
        exclude: [String] = [],
        message: String,
        severity: Diagnostic.Severity = .warning
    ) {
        self.id = id
        self.pattern = pattern
        self.include = include
        self.exclude = exclude
        self.message = message
        self.severity = severity
    }

    private enum CodingKeys: String, CodingKey {
        case id, pattern, include, exclude, message, severity
    }

    /// Decodes with defaults for absent optional keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        pattern = try container.decode(String.self, forKey: .pattern)
        include = try container.decodeIfPresent([String].self, forKey: .include) ?? []
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? []
        message = try container.decode(String.self, forKey: .message)
        severity = try container.decodeIfPresent(Diagnostic.Severity.self, forKey: .severity) ?? .warning
    }
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
/// vendorPaths:
///   - polar-ble-sdk
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
/// customRules:
///   - id: house.no-print
///     pattern: 'print\('
///     exclude:
///       - "Tests/"
///     message: "use os.Logger, not print()"
///     severity: warning
/// ```
public struct Configuration: Sendable, Codable, Equatable {

    /// Number of parallel workers for test execution.
    /// If nil, defaults to 80% of system cores.
    public var parallelWorkers: Int?

    /// Glob patterns for files/directories to exclude from checks.
    public var excludePatterns: [String]

    /// Path prefixes for vendor/third-party code.
    ///
    /// Diagnostics in these paths are demoted to `.note` severity so they
    /// remain visible for tracking without failing the gate.
    public var vendorPaths: [String]

    /// Comment patterns that suppress safety warnings.
    public var safetyExemptions: [String]

    /// Checkers to run. Empty means all checkers are enabled.
    public var enabledCheckers: [String]

    /// Build configuration to use (debug or release). Defaults to debug.
    public var buildConfiguration: String?

    /// Test filter pattern for running specific tests.
    public var testFilter: String?

    /// Documentation target for DocC linting.
    /// If nil, auto-detects the first library product target from Package.swift.
    public var docTarget: String?

    /// Minimum documentation coverage percentage (0-100).
    /// If nil, any undocumented public API triggers a warning.
    /// If set, coverage below threshold triggers failure, otherwise passes.
    public var docCoverageThreshold: Int?

    /// v5: Opt in to driving `xcodebuild build` automatically when the
    /// `unreachable` checker can't find a fresh DerivedData index store
    /// for an Xcode project. Default: false (slow + side-effect-y).
    public var unreachableAutoBuildXcode: Bool

    /// v5: Override the auto-detected scheme for `xcodebuild`. nil ⇒
    /// pick the first scheme reported by `xcodebuild -list -json`.
    public var xcodeScheme: String?

    /// v5: Override the auto-build destination. Default
    /// `"generic/platform=macOS"`.
    public var xcodeDestination: String?

    /// Per-checker configuration for RecursionAuditor.
    public var recursion: RecursionAuditorConfig

    /// Per-checker configuration for ConcurrencyAuditor.
    public var concurrency: ConcurrencyAuditorConfig

    /// Per-checker configuration for PointerEscapeAuditor.
    public var pointerEscape: PointerEscapeAuditorConfig

    /// Per-checker configuration for SecurityVisitor (within SafetyAuditor).
    public var security: SecurityAuditorConfig

    /// Per-checker configuration for StatusAuditor.
    public var status: StatusAuditorConfig

    /// Per-checker configuration for SwiftVersionChecker.
    public var swiftVersion: SwiftVersionConfig

    /// Per-checker configuration for MemoryBuilder.
    public var memoryBuilder: MemoryBuilderConfig

    /// Per-checker configuration for LoggingAuditor.
    public var logging: LoggingAuditorConfig

    /// Per-checker configuration for DependencyAuditor.
    public var dependencyAudit: DependencyAuditorConfig

    /// Per-checker configuration for SubmoduleAuditor.
    public var submoduleAudit: SubmoduleAuditorConfig

    /// Per-checker configuration for ReleaseReadinessAuditor.
    public var releaseReadiness: ReleaseReadinessAuditorConfig

    /// Per-checker configuration for FloatingPointSafetyAuditor.
    public var fpSafety: FloatingPointSafetyAuditorConfig

    /// Per-checker configuration for StochasticDeterminismAuditor.
    public var stochasticDeterminism: StochasticDeterminismConfig

    /// Configuration for the temporal determinism auditor.
    public var temporalDeterminism: TemporalDeterminismConfig

    /// Configuration for the test-outcome flip detector (within TestRunner).
    public var flipDetector: FlipDetectorConfig

    /// Configuration for deliberate stress runs of timing-tagged tests (within TestRunner).
    public var stress: StressTestConfig

    /// Per-checker configuration for MemoryLifecycleGuard.
    public var memoryLifecycle: MemoryLifecycleConfig

    /// Per-checker configuration for MCPReadinessAuditor.
    public var mcpReadiness: MCPReadinessConfig

    /// Per-checker configuration for AppIntentsAuditor.
    public var appIntentsReadiness: AppIntentsReadinessConfig

    /// Per-checker configuration for BuildChecker.
    public var build: BuildCheckerConfig

    /// Per-checker configuration for XcodeBuildChecker.
    public var xcodeBuild: XcodeBuildCheckerConfig

    /// Per-checker configuration for ConsistencyChecker (IJS).
    public var consistency: ConsistencyCheckerConfig

    /// Per-checker configuration for ComplexityAnalyzer (advisory).
    public var complexity: ComplexityAnalyzerConfig

    /// Per-checker configuration for LegibilityAnalyzer (advisory).
    public var legibility: LegibilityAnalyzerConfig

    /// Per-checker configuration for DocCoverageChecker.
    public var docCoverage: DocCoverageConfig

    /// Per-rule severity overrides from configuration.
    ///
    /// Keys are rule IDs (e.g. `"safety.force-unwrap"`) or wildcard patterns
    /// (e.g. `"safety.*"`). Applied after checkers return results, before reporting.
    public var overrides: [String: SeverityOverride]

    /// Tier-2 executable plugins (Phase 4b). Empty by default.
    public var plugins: [PluginConfig]

    /// Tier-1 declarative custom rules (Phase 4b). Empty by default.
    public var customRules: [CustomRuleConfig]

    /// Idiom-rule knobs (Phase 4c §1). Defaults match SwiftLint's head.
    public var idiom: IdiomConfig

    /// Smell-metric thresholds (Phase 4c §4).
    public var smells: SmellConfig

    /// Duplicate-code detection knobs (Phase 4c §2).
    public var duplication: DuplicationConfig

    /// `keychain-secrets` checker knobs — severity, allow-list, extra nouns.
    public var keychainSecrets: KeychainSecretsConfig

    /// `privacy-manifest` checker knobs — app-target override, key strictness.
    public var privacyManifest: PrivacyManifestConfig

    /// `doc-code` checker knobs — extra articles, imports, module search path.
    public var docCode: DocCodeConfig

    /// Minimum gate build this repo requires (`YYYY-MM-DD` or full ISO8601).
    /// A stale installed binary warns — or fails under `--strict` — instead of
    /// silently running old rules (Phase 0.6). nil means no pin.
    public var minimumGateVersion: String?

    /// Creates a new configuration with the specified values.
    public init(
        parallelWorkers: Int? = nil,
        excludePatterns: [String] = [],
        vendorPaths: [String] = [],
        safetyExemptions: [String] = ["// SAFETY:"],
        enabledCheckers: [String] = [],
        buildConfiguration: String? = nil,
        testFilter: String? = nil,
        docTarget: String? = nil,
        docCoverageThreshold: Int? = nil,
        unreachableAutoBuildXcode: Bool = false,
        xcodeScheme: String? = nil,
        xcodeDestination: String? = nil,
        recursion: RecursionAuditorConfig = .default,
        concurrency: ConcurrencyAuditorConfig = .default,
        pointerEscape: PointerEscapeAuditorConfig = .default,
        security: SecurityAuditorConfig = .default,
        status: StatusAuditorConfig = .default,
        swiftVersion: SwiftVersionConfig = .default,
        memoryBuilder: MemoryBuilderConfig = .default,
        logging: LoggingAuditorConfig = .default,
        dependencyAudit: DependencyAuditorConfig = .default,
        submoduleAudit: SubmoduleAuditorConfig = .default,
        releaseReadiness: ReleaseReadinessAuditorConfig = .default,
        fpSafety: FloatingPointSafetyAuditorConfig = .default,
        stochasticDeterminism: StochasticDeterminismConfig = .default,
        temporalDeterminism: TemporalDeterminismConfig = .default,
        flipDetector: FlipDetectorConfig = .default,
        stress: StressTestConfig = .default,
        memoryLifecycle: MemoryLifecycleConfig = .default,
        mcpReadiness: MCPReadinessConfig = .default,
        appIntentsReadiness: AppIntentsReadinessConfig = .default,
        build: BuildCheckerConfig = .default,
        xcodeBuild: XcodeBuildCheckerConfig = .default,
        consistency: ConsistencyCheckerConfig = .default,
        complexity: ComplexityAnalyzerConfig = .default,
        legibility: LegibilityAnalyzerConfig = .default,
        docCoverage: DocCoverageConfig = .default,
        overrides: [String: SeverityOverride] = [:],
        plugins: [PluginConfig] = [],
        customRules: [CustomRuleConfig] = [],
        idiom: IdiomConfig = IdiomConfig(),
        smells: SmellConfig = SmellConfig(),
        duplication: DuplicationConfig = DuplicationConfig(),
        keychainSecrets: KeychainSecretsConfig = KeychainSecretsConfig(),
        privacyManifest: PrivacyManifestConfig = PrivacyManifestConfig(),
        docCode: DocCodeConfig = DocCodeConfig(),
        minimumGateVersion: String? = nil
    ) {
        self.minimumGateVersion = minimumGateVersion
        self.parallelWorkers = parallelWorkers
        self.excludePatterns = excludePatterns
        self.vendorPaths = vendorPaths
        self.safetyExemptions = safetyExemptions
        self.enabledCheckers = enabledCheckers
        self.buildConfiguration = buildConfiguration
        self.testFilter = testFilter
        self.docTarget = docTarget
        self.docCoverageThreshold = docCoverageThreshold
        self.unreachableAutoBuildXcode = unreachableAutoBuildXcode
        self.xcodeScheme = xcodeScheme
        self.xcodeDestination = xcodeDestination
        self.recursion = recursion
        self.concurrency = concurrency
        self.pointerEscape = pointerEscape
        self.security = security
        self.status = status
        self.swiftVersion = swiftVersion
        self.memoryBuilder = memoryBuilder
        self.logging = logging
        self.dependencyAudit = dependencyAudit
        self.submoduleAudit = submoduleAudit
        self.releaseReadiness = releaseReadiness
        self.fpSafety = fpSafety
        self.stochasticDeterminism = stochasticDeterminism
        self.temporalDeterminism = temporalDeterminism
        self.flipDetector = flipDetector
        self.stress = stress
        self.memoryLifecycle = memoryLifecycle
        self.mcpReadiness = mcpReadiness
        self.appIntentsReadiness = appIntentsReadiness
        self.build = build
        self.xcodeBuild = xcodeBuild
        self.consistency = consistency
        self.complexity = complexity
        self.legibility = legibility
        self.docCoverage = docCoverage
        self.overrides = overrides
        self.plugins = plugins
        self.customRules = customRules
        self.idiom = idiom
        self.smells = smells
        self.duplication = duplication
        self.keychainSecrets = keychainSecrets
        self.privacyManifest = privacyManifest
        self.docCode = docCode
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
        case vendorPaths
        case safetyExemptions
        case enabledCheckers
        case buildConfiguration
        case testFilter
        case docTarget
        case docCoverageThreshold
        case unreachableAutoBuildXcode
        case xcodeScheme
        case xcodeDestination
        case recursion
        case concurrency
        case pointerEscape
        case security
        case status
        case swiftVersion
        case memoryBuilder
        case logging
        case dependencyAudit
        case submoduleAudit
        case releaseReadiness
        case fpSafety
        case stochasticDeterminism
        case temporalDeterminism
        case flipDetector
        case stress
        case memoryLifecycle
        case mcpReadiness
        case appIntentsReadiness
        case build
        case xcodeBuild
        case consistency
        case complexity
        case legibility
        case docCoverage
        case overrides
        case plugins
        case customRules
        case idiom
        case smells
        case duplication
        case keychainSecrets = "keychain-secrets"
        case privacyManifest = "privacy-manifest"
        case docCode = "doc-code"
        case minimumGateVersion
    }

    /// Creates a configuration by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        parallelWorkers = try container.decodeIfPresent(Int.self, forKey: .parallelWorkers)
        excludePatterns = try container.decodeIfPresent([String].self, forKey: .excludePatterns) ?? []
        vendorPaths = try container.decodeIfPresent([String].self, forKey: .vendorPaths) ?? []
        safetyExemptions = try container.decodeIfPresent([String].self, forKey: .safetyExemptions) ?? ["// SAFETY:"]
        enabledCheckers = try container.decodeIfPresent([String].self, forKey: .enabledCheckers) ?? []
        buildConfiguration = try container.decodeIfPresent(String.self, forKey: .buildConfiguration)
        testFilter = try container.decodeIfPresent(String.self, forKey: .testFilter)
        docTarget = try container.decodeIfPresent(String.self, forKey: .docTarget)
        docCoverageThreshold = try container.decodeIfPresent(Int.self, forKey: .docCoverageThreshold)
        unreachableAutoBuildXcode = try container.decodeIfPresent(Bool.self, forKey: .unreachableAutoBuildXcode) ?? false
        xcodeScheme = try container.decodeIfPresent(String.self, forKey: .xcodeScheme)
        xcodeDestination = try container.decodeIfPresent(String.self, forKey: .xcodeDestination)
        recursion = try container.decodeIfPresent(RecursionAuditorConfig.self, forKey: .recursion) ?? .default
        concurrency = try container.decodeIfPresent(ConcurrencyAuditorConfig.self, forKey: .concurrency) ?? .default
        pointerEscape = try container.decodeIfPresent(PointerEscapeAuditorConfig.self, forKey: .pointerEscape) ?? .default
        security = try container.decodeIfPresent(SecurityAuditorConfig.self, forKey: .security) ?? .default
        status = try container.decodeIfPresent(StatusAuditorConfig.self, forKey: .status) ?? .default
        swiftVersion = try container.decodeIfPresent(SwiftVersionConfig.self, forKey: .swiftVersion) ?? .default
        memoryBuilder = try container.decodeIfPresent(MemoryBuilderConfig.self, forKey: .memoryBuilder) ?? .default
        logging = try container.decodeIfPresent(LoggingAuditorConfig.self, forKey: .logging) ?? .default
        dependencyAudit = try container.decodeIfPresent(DependencyAuditorConfig.self, forKey: .dependencyAudit) ?? .default
        submoduleAudit = try container.decodeIfPresent(SubmoduleAuditorConfig.self, forKey: .submoduleAudit) ?? .default
        releaseReadiness = try container.decodeIfPresent(ReleaseReadinessAuditorConfig.self, forKey: .releaseReadiness) ?? .default
        fpSafety = try container.decodeIfPresent(FloatingPointSafetyAuditorConfig.self, forKey: .fpSafety) ?? .default
        stochasticDeterminism = try container.decodeIfPresent(StochasticDeterminismConfig.self, forKey: .stochasticDeterminism) ?? .default
        temporalDeterminism = try container.decodeIfPresent(TemporalDeterminismConfig.self, forKey: .temporalDeterminism) ?? .default
        flipDetector = try container.decodeIfPresent(FlipDetectorConfig.self, forKey: .flipDetector) ?? .default
        stress = try container.decodeIfPresent(StressTestConfig.self, forKey: .stress) ?? .default
        memoryLifecycle = try container.decodeIfPresent(MemoryLifecycleConfig.self, forKey: .memoryLifecycle) ?? .default
        mcpReadiness = try container.decodeIfPresent(MCPReadinessConfig.self, forKey: .mcpReadiness) ?? .default
        appIntentsReadiness = try container.decodeIfPresent(AppIntentsReadinessConfig.self, forKey: .appIntentsReadiness) ?? .default
        build = try container.decodeIfPresent(BuildCheckerConfig.self, forKey: .build) ?? .default
        xcodeBuild = try container.decodeIfPresent(XcodeBuildCheckerConfig.self, forKey: .xcodeBuild) ?? .default
        consistency = try container.decodeIfPresent(ConsistencyCheckerConfig.self, forKey: .consistency) ?? .default
        complexity = try container.decodeIfPresent(ComplexityAnalyzerConfig.self, forKey: .complexity) ?? .default
        legibility = try container.decodeIfPresent(LegibilityAnalyzerConfig.self, forKey: .legibility) ?? .default
        docCoverage = try container.decodeIfPresent(DocCoverageConfig.self, forKey: .docCoverage) ?? .default
        overrides = try container.decodeIfPresent([String: SeverityOverride].self, forKey: .overrides) ?? [:]
        plugins = try container.decodeIfPresent([PluginConfig].self, forKey: .plugins) ?? []
        customRules = try container.decodeIfPresent([CustomRuleConfig].self, forKey: .customRules) ?? []
        idiom = try container.decodeIfPresent(IdiomConfig.self, forKey: .idiom) ?? IdiomConfig()
        smells = try container.decodeIfPresent(SmellConfig.self, forKey: .smells) ?? SmellConfig()
        duplication = try container.decodeIfPresent(DuplicationConfig.self, forKey: .duplication) ?? DuplicationConfig()
        keychainSecrets = try container.decodeIfPresent(KeychainSecretsConfig.self, forKey: .keychainSecrets) ?? KeychainSecretsConfig()
        privacyManifest = try container.decodeIfPresent(PrivacyManifestConfig.self, forKey: .privacyManifest) ?? PrivacyManifestConfig()
        docCode = try container.decodeIfPresent(DocCodeConfig.self, forKey: .docCode) ?? DocCodeConfig()
        minimumGateVersion = try container.decodeIfPresent(String.self, forKey: .minimumGateVersion)
    }
}
