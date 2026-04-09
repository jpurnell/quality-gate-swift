import Foundation
import Yams

/// Per-checker configuration for ConcurrencyAuditor.
public struct ConcurrencyAuditorConfig: Sendable, Codable, Equatable {
    /// Comment keyword that suppresses unchecked-Sendable / nonisolated-unsafe rules.
    public let justificationKeyword: String
    /// Module names that are allowed to keep `@preconcurrency import` even if first-party.
    public let allowPreconcurrencyImports: [String]

    public init(
        justificationKeyword: String = "Justification:",
        allowPreconcurrencyImports: [String] = []
    ) {
        self.justificationKeyword = justificationKeyword
        self.allowPreconcurrencyImports = allowPreconcurrencyImports
    }

    public static let `default` = ConcurrencyAuditorConfig()
}

/// Per-checker configuration for PointerEscapeAuditor.
public struct PointerEscapeAuditorConfig: Sendable, Codable, Equatable {
    /// Function names allowed to receive a borrowed pointer (escape suppression).
    public let allowedEscapeFunctions: [String]

    public init(allowedEscapeFunctions: [String] = []) {
        self.allowedEscapeFunctions = allowedEscapeFunctions
    }

    public static let `default` = PointerEscapeAuditorConfig()
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
        pointerEscape: PointerEscapeAuditorConfig = .default
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

        guard fileManager.fileExists(atPath: path) else {
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
    }
}
