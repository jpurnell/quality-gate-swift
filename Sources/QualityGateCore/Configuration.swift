import Foundation
import Yams

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
    /// If nil, lints all targets with documentation catalogs.
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
        logging: LoggingAuditorConfig = .default
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
    }
}
