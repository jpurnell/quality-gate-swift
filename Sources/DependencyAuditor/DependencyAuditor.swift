import Foundation
import QualityGateCore

// MARK: - Package.resolved Models

/// Represents the decoded contents of a `Package.resolved` file (v2/v3 format).
struct PackageResolved: Sendable, Codable {
    /// The array of pinned dependencies.
    let pins: [ResolvedPin]
    /// The format version of the resolved file.
    let version: Int? // LIVE: Codable synthesized decode
}

/// A single pinned dependency in `Package.resolved`.
struct ResolvedPin: Sendable, Codable {
    /// The lowercased package identity (e.g. `"swift-syntax"`).
    let identity: String
    /// The kind of source control (e.g. `"remoteSourceControl"`).
    let kind: String? // LIVE: Codable synthesized decode
    /// The repository URL.
    let location: String // LIVE: Codable synthesized decode
    /// The resolved state — version, branch, or bare revision.
    let state: PinState
}

/// The resolution state of a single dependency pin.
struct PinState: Sendable, Codable {
    /// If the pin tracks a branch, the branch name; otherwise `nil`.
    let branch: String?
    /// The pinned Git revision hash.
    let revision: String? // LIVE: Codable synthesized decode
    /// If the pin tracks a version tag, the semantic version string; otherwise `nil`.
    let version: String? // LIVE: Codable synthesized decode
}

// MARK: - DependencyAuditor

/// Audits SPM dependency hygiene without touching the network.
///
/// Checks that `Package.resolved` is present and in sync with `Package.swift`,
/// flags branch-pinned dependencies, and detects active `swift package edit` overrides.
///
/// ## Rules
///
/// | Rule ID | What it flags | Severity |
/// |---|---|---|
/// | `dep-unresolved` | `Package.resolved` missing or out of sync | error |
/// | `dep-branch-pin` | Dependency pinned to a branch instead of version | warning |
/// | `dep-local-override` | `swift package edit` overrides active | warning |
///
/// ## Usage
///
/// ```swift
/// let auditor = DependencyAuditor()
/// let result = try await auditor.check(configuration: config)
/// ```
public struct DependencyAuditor: QualityChecker, Sendable {

    /// Unique identifier for this checker.
    public let id = "dependency-audit"

    /// Human-readable name for display.
    public let name = "Dependency Auditor"

    /// Creates a new DependencyAuditor instance.
    public init() {}

    /// Run the dependency audit.
    ///
    /// Inspects `Package.resolved` and `Package.swift` in the current working
    /// directory to detect unresolved dependencies, branch pins, and local overrides.
    ///
    /// - Parameter configuration: Project-specific configuration.
    /// - Returns: The check result with status and diagnostics.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let clock = ContinuousClock()
        let start = clock.now

        let projectRoot = FileManager.default.currentDirectoryPath
        let packageSwiftPath = projectRoot + "/Package.swift"
        let hasRootManifest = FileManager.default.fileExists(atPath: packageSwiftPath) // SAFETY: CLI reads Package.swift from cwd

        var diagnostics: [Diagnostic] = []
        let packageSwiftContent = hasRootManifest
            // silent: missing Package.swift handled by empty string fallback
            ? ((try? String(contentsOfFile: packageSwiftPath, encoding: .utf8)) ?? "")
            : ""
        var pins: [ResolvedPin] = []

        // --- SPM-specific rules (require root Package.swift) ---
        if hasRootManifest {
            let resolvedPath = projectRoot + "/Package.resolved"
            let resolvedExists = FileManager.default.fileExists(atPath: resolvedPath) // SAFETY: reads local project file
            let packageSwiftURLs = Self.extractPackageURLs(from: packageSwiftContent)

            var resolvedPinCount = 0

            if resolvedExists {
                if let data = FileManager.default.contents(atPath: resolvedPath), // SAFETY: reads local project file
                   let json = String(data: data, encoding: .utf8),
                   let resolved = try? Self.parsePackageResolved(json) { // silent: malformed Package.resolved handled gracefully
                    resolvedPinCount = resolved.pins.count
                    pins = resolved.pins
                }
            }

            let unresolvedDiagnostics = Self.checkUnresolved(
                resolvedExists: resolvedExists,
                resolvedPinCount: resolvedPinCount,
                packageSwiftDependencyCount: packageSwiftURLs.count
            )
            diagnostics.append(contentsOf: unresolvedDiagnostics)

            // --- dep-branch-pin ---
            let branchDiagnostics = Self.checkBranchPins(
                pins: pins,
                config: configuration.dependencyAudit
            )
            diagnostics.append(contentsOf: branchDiagnostics)

            // --- dep-local-override ---
            let overrideDiagnostics = Self.checkLocalOverrides(projectRoot: projectRoot)
            diagnostics.append(contentsOf: overrideDiagnostics)
        }

        // --- dep-hallucinated-import (works with or without root Package.swift) ---
        let importDiagnostics = Self.runHallucinatedImportCheck(
            projectRoot: projectRoot,
            packageSwiftContent: packageSwiftContent,
            pins: pins,
            config: configuration.dependencyAudit
        )
        diagnostics.append(contentsOf: importDiagnostics)

        let duration = start.duration(to: clock.now)

        // If no root manifest AND no subdirectory manifests found, skip entirely
        if !hasRootManifest && diagnostics.isEmpty {
            let manifests = Self.discoverPackageManifests(in: projectRoot)
            if manifests.isEmpty {
                return CheckResult(
                    checkerId: id,
                    status: .skipped,
                    diagnostics: [
                        Diagnostic(
                            severity: .note,
                            message: "No Package.swift found; skipping dependency audit.",
                            ruleId: "dep-skip"
                        )
                    ],
                    duration: duration
                )
            }
        }

        let status = Self.computeStatus(from: diagnostics)

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    // MARK: - Internal Helpers

    /// Parses a `Package.resolved` JSON string into a ``PackageResolved`` model.
    ///
    /// Supports both v2 and v3 formats (both use the `"pins"` key).
    ///
    /// - Parameter json: The raw JSON content of `Package.resolved`.
    /// - Returns: The decoded resolved file model.
    /// - Throws: `DecodingError` if the JSON is malformed.
    static func parsePackageResolved(_ json: String) throws -> PackageResolved {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        return try decoder.decode(PackageResolved.self, from: data)
    }

    /// Extracts dependency URLs from `Package.swift` content using pattern matching.
    ///
    /// Handles both `.package(url:` and `.package(name:, url:` formats.
    ///
    /// - Parameter content: The raw text of `Package.swift`.
    /// - Returns: An array of dependency URL strings.
    static func extractPackageURLs(from content: String) -> [String] {
        // Match both .package(url: "...") and .package(name: "...", url: "...") patterns
        let pattern = #"\.package\([^)]*url:\s*"([^"]+)""#
        // silent: constant regex pattern
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)

        return matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let urlRange = Range(match.range(at: 1), in: content) else {
                return nil
            }
            return String(content[urlRange])
        }
    }

    /// Extracts explicit package `name:` parameters from dependency declarations.
    ///
    /// Handles `.package(name: "RxSwift", ...)` which declares the package identity.
    ///
    /// - Parameter content: The raw text of `Package.swift`.
    /// - Returns: An array of declared package names.
    static func extractPackageDeclaredNames(from content: String) -> [String] {
        let pattern = #"\.package\(\s*name:\s*"([^"]+)""#
        // silent: constant regex pattern
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)
        return matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[nameRange])
        }
    }

    /// Extracts target `exclude:` paths from a `Package.swift` content string.
    static func extractExcludePaths(from content: String) -> [String] {
        let pattern = #"exclude:\s*\[((?:[^\]]*?"[^"]*"[^\]]*?)*)\]"#
        // silent: constant regex pattern
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)

        let stringPattern = #""([^"]+)""#
        // silent: constant regex pattern
        guard let stringRegex = try? NSRegularExpression(pattern: stringPattern, options: []) else {
            return []
        }

        var paths: [String] = []
        for match in matches {
            guard let arrayRange = Range(match.range(at: 1), in: content) else { continue }
            let arrayContent = String(content[arrayRange])
            let arrayNSRange = NSRange(arrayContent.startIndex..., in: arrayContent)
            let stringMatches = stringRegex.matches(in: arrayContent, options: [], range: arrayNSRange)
            for sm in stringMatches {
                guard sm.numberOfRanges >= 2,
                      let strRange = Range(sm.range(at: 1), in: arrayContent) else { continue }
                paths.append(String(arrayContent[strRange]))
            }
        }
        return paths
    }

    /// Checks whether `Package.resolved` exists and is in sync with `Package.swift`.
    ///
    /// When resolved is missing entirely, or has fewer pins than direct dependencies
    /// declared in `Package.swift`, an error diagnostic is produced.
    ///
    /// - Parameters:
    ///   - resolvedExists: Whether `Package.resolved` exists on disk.
    ///   - resolvedPinCount: Number of pins in `Package.resolved`.
    ///   - packageSwiftDependencyCount: Number of direct dependencies in `Package.swift`.
    /// - Returns: Diagnostics for any unresolved dependency issues.
    static func checkUnresolved(
        resolvedExists: Bool,
        resolvedPinCount: Int,
        packageSwiftDependencyCount: Int
    ) -> [Diagnostic] {
        guard resolvedExists else {
            return [
                Diagnostic(
                    severity: .error,
                    message: "Package.resolved is missing — run `swift package resolve`",
                    filePath: "Package.resolved",
                    ruleId: "dep-unresolved"
                ),
            ]
        }

        // Resolved can have MORE pins than Package.swift (transitive dependencies),
        // but should never have FEWER than the direct dependency count.
        guard resolvedPinCount < packageSwiftDependencyCount else {
            return []
        }

        return [
            Diagnostic(
                severity: .error,
                message: "Package.resolved is out of sync with Package.swift "
                    + "(resolved has \(resolvedPinCount) pins, "
                    + "Package.swift declares \(packageSwiftDependencyCount) direct dependencies) "
                    + "— run `swift package resolve`",
                filePath: "Package.resolved",
                ruleId: "dep-unresolved"
            ),
        ]
    }

    /// Checks for dependencies pinned to a branch instead of a version tag.
    ///
    /// Branch pins are inherently unstable and can break reproducible builds.
    /// Identities listed in `config.allowBranchPins` are exempted.
    ///
    /// - Parameters:
    ///   - pins: The resolved dependency pins to inspect.
    ///   - config: The dependency auditor configuration.
    /// - Returns: Warning diagnostics for each non-allowlisted branch pin.
    static func checkBranchPins(
        pins: [ResolvedPin],
        config: DependencyAuditorConfig
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        for pin in pins {
            guard let branch = pin.state.branch else { continue }
            guard !config.allowBranchPins.contains(pin.identity) else { continue }

            diagnostics.append(
                Diagnostic(
                    severity: .warning,
                    message: "'\(pin.identity)' is pinned to branch '\(branch)' instead of a version tag",
                    filePath: "Package.resolved",
                    ruleId: "dep-branch-pin"
                )
            )
        }

        return diagnostics
    }

    /// Checks for active `swift package edit` overrides.
    ///
    /// When a developer runs `swift package edit <dep>`, SPM creates workspace
    /// state that can accidentally be committed. This check looks for the
    /// `.swiftpm/xcode/package.xcworkspace` directory or workspace-state files
    /// that indicate active overrides.
    ///
    /// - Parameter projectRoot: The project root directory path.
    /// - Returns: Warning diagnostics if local overrides are detected.
    static func checkLocalOverrides(projectRoot: String) -> [Diagnostic] {
        let fm = FileManager.default // SAFETY: reads local project directory
        let workspaceStatePath = projectRoot + "/.swiftpm/workspace/state.json"
        // SECURITY: CLI tool reads local SPM workspace state — path derived from validated project root
        guard fm.fileExists(atPath: workspaceStatePath),
              // SECURITY: reads workspace state from validated local project path
              let data = fm.contents(atPath: workspaceStatePath),
              let json = String(data: data, encoding: .utf8) else {
            return []
        }

        // Check for "dependencies" entries with "state" containing "edited" or "local"
        // A simple heuristic: if the file contains "edited" in a meaningful context
        guard json.contains("\"edited\"") || json.contains("\"isEdited\" : true") else {
            return []
        }

        return [
            Diagnostic(
                severity: .warning,
                message: "`swift package edit` overrides are active — "
                    + "ensure these are intentional before committing",
                filePath: ".swiftpm/workspace/state.json",
                ruleId: "dep-local-override"
            ),
        ]
    }

    /// Orchestrates the hallucinated import check using filesystem discovery.
    static func runHallucinatedImportCheck(
        projectRoot: String,
        packageSwiftContent: String,
        pins: [ResolvedPin],
        config: DependencyAuditorConfig
    ) -> [Diagnostic] {
        let fm = FileManager.default
        var knownModules = systemFrameworks

        // Add targets and products from root Package.swift
        let rootTargets = extractTargetNames(from: packageSwiftContent)
        let rootProducts = extractProductNames(from: packageSwiftContent)
        knownModules.formUnion(rootTargets)
        knownModules.formUnion(rootProducts)
        knownModules.formUnion(extractPackageDeclaredNames(from: packageSwiftContent))

        // Add targets from all discovered Package.swift files (monorepo support)
        let manifests = discoverPackageManifests(in: projectRoot)
        for manifestPath in manifests {
            // silent: unreadable manifest files skipped gracefully
            guard let content = try? String(contentsOfFile: manifestPath, encoding: .utf8) else { continue }
            knownModules.formUnion(extractTargetNames(from: content))
            knownModules.formUnion(extractProductNames(from: content))
            knownModules.formUnion(extractPackageDeclaredNames(from: content))
        }

        // Add package identities and derived names from Package.resolved
        for pin in pins {
            addPinDerivedNames(pin: pin, into: &knownModules)
        }

        // Also scan Package.resolved files in subdirectories (monorepo)
        for manifestPath in manifests {
            let packageDir = (manifestPath as NSString).deletingLastPathComponent
            let resolvedPath = (packageDir as NSString).appendingPathComponent("Package.resolved")
            // SAFETY: CLI reads Package.resolved from discovered local package directories
            guard let data = fm.contents(atPath: resolvedPath),
                  let json = String(data: data, encoding: .utf8) else { continue }
            let resolvedPins = parseResolvedPins(from: json)
            for pin in resolvedPins {
                addPinDerivedNames(pin: pin, into: &knownModules)
            }
        }

        // Derive module names from package URLs in all manifests
        var allManifestContents: [(path: String, content: String)] = []
        for manifestPath in manifests {
            // silent: unreadable manifest files skipped gracefully
            guard let content = try? String(contentsOfFile: manifestPath, encoding: .utf8) else { continue }
            allManifestContents.append((path: manifestPath, content: content))
            addURLDerivedNames(from: content, into: &knownModules)
        }
        if !packageSwiftContent.isEmpty {
            addURLDerivedNames(from: packageSwiftContent, into: &knownModules)
        }

        // Add user-configured additional modules
        knownModules.formUnion(config.additionalKnownModules)

        // Discover source files from each package's Sources/ and Tests/ directories,
        // respecting exclude: paths declared in each Package.swift
        var sourceFiles: [(path: String, content: String)] = []

        var packageRoots: [String] = []
        if !packageSwiftContent.isEmpty {
            packageRoots.append(projectRoot)
        }
        for manifestPath in manifests {
            let packageDir = (manifestPath as NSString).deletingLastPathComponent
            if packageDir != projectRoot {
                packageRoots.append(packageDir)
            }
        }

        for packageRoot in packageRoots {
            // Get exclude paths for this package
            let manifestPath = (packageRoot as NSString).appendingPathComponent("Package.swift")
            // silent: unreadable manifest defaults to empty (no excludes applied)
            let manifestContent = (try? String(contentsOfFile: manifestPath, encoding: .utf8)) ?? ""
            let excludePaths = extractExcludePaths(from: manifestContent)

            for dir in ["Sources", "Tests"] {
                let dirPath = (packageRoot as NSString).appendingPathComponent(dir)
                guard let enumerator = fm.enumerator(atPath: dirPath) else { continue }
                while let relativePath = enumerator.nextObject() as? String {
                    guard relativePath.hasSuffix(".swift") else { continue }

                    // Skip files within excluded directories
                    let shouldExclude = excludePaths.contains { excludePath in
                        relativePath.hasPrefix(excludePath + "/") || relativePath == excludePath
                    }
                    guard !shouldExclude else { continue }

                    let fullPath = (dirPath as NSString).appendingPathComponent(relativePath)
                    // silent: unreadable files skipped gracefully
                    guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
                    let relativeToRoot = fullPath.hasPrefix(projectRoot)
                        ? String(fullPath.dropFirst(projectRoot.count + 1))
                        : fullPath
                    sourceFiles.append((path: relativeToRoot, content: content))
                }
            }
        }

        return checkHallucinatedImports(sourceFiles: sourceFiles, knownModules: knownModules)
    }

    /// Adds identity, PascalCase, and URL-derived names from a resolved pin.
    private static func addPinDerivedNames(pin: ResolvedPin, into modules: inout Set<String>) {
        modules.insert(pin.identity)
        let pascalCase = pin.identity
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
        modules.insert(pascalCase)
        // Derive from location URL (preserves original casing, e.g. "RxSwift")
        var urlName = (pin.location as NSString).lastPathComponent
        if urlName.hasSuffix(".git") {
            urlName = String(urlName.dropLast(4))
        }
        if !urlName.isEmpty {
            modules.insert(urlName)
            let urlPascal = urlName
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined()
            modules.insert(urlPascal)
        }
    }

    /// Adds URL-derived module names from a Package.swift content string.
    private static func addURLDerivedNames(from content: String, into modules: inout Set<String>) {
        let urls = extractPackageURLs(from: content)
        for url in urls {
            var name = (url as NSString).lastPathComponent
            if name.hasSuffix(".git") {
                name = String(name.dropLast(4))
            }
            modules.insert(name)
            let pascalCase = name
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined()
            modules.insert(pascalCase)
        }
    }

    /// Parses resolved pins from JSON, handling both v1 and v2/v3 formats.
    static func parseResolvedPins(from json: String) -> [ResolvedPin] {
        // silent: v2/v3 decode failure falls through to v1 parser
        if let resolved = try? parsePackageResolved(json) {
            return resolved.pins
        }
        // Try v1 format: {"object": {"pins": [...]}, "version": 1}
        if let v1 = parsePackageResolvedV1(json) {
            return v1
        }
        return []
    }

    /// Parses a v1 format Package.resolved into ResolvedPin array.
    static func parsePackageResolvedV1(_ json: String) -> [ResolvedPin]? {
        let data = Data(json.utf8)
        // silent: JSON decoding of local file
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objectDict = obj["object"] as? [String: Any],
              let pinsArray = objectDict["pins"] as? [[String: Any]] else {
            return nil
        }
        return pinsArray.compactMap { pinDict -> ResolvedPin? in
            guard let packageName = pinDict["package"] as? String,
                  let repositoryURL = pinDict["repositoryURL"] as? String,
                  let stateDict = pinDict["state"] as? [String: Any] else { return nil }
            let branch = stateDict["branch"] as? String
            let revision = stateDict["revision"] as? String
            let version = stateDict["version"] as? String
            return ResolvedPin(
                identity: packageName.lowercased(),
                kind: "remoteSourceControl",
                location: repositoryURL,
                state: PinState(branch: branch, revision: revision, version: version)
            )
        }
    }

    // MARK: - Hallucinated Import Detection

    /// A parsed import statement from a source file.
    public struct ImportStatement: Sendable {
        /// The root module name (e.g., "Foundation" from `import Foundation`).
        public let moduleName: String
        /// The 1-based line number in the source file.
        public let line: Int
        /// Whether this import is inside a `#if canImport(X)` guard for the same module.
        public let isCanImportGuarded: Bool
    }

    /// Known Apple/system frameworks and C modules that don't appear in Package.swift.
    public static let systemFrameworks: Set<String> = [
        // Runtime
        "Foundation", "Darwin", "Glibc", "WinSDK", "Dispatch", "ObjectiveC",
        "Swift", "_Concurrency", "_StringProcessing", "Synchronization",
        // UI
        "UIKit", "AppKit", "SwiftUI", "WatchKit", "TVUIKit",
        // Data
        "CoreData", "SwiftData", "CloudKit",
        // Combine / Observation
        "Combine", "Observation", "OpenCombine",
        // Media
        "AVFoundation", "AVKit", "AudioToolbox", "CoreAudio", "MediaPlayer",
        "CoreImage", "CoreGraphics", "CoreText", "QuartzCore", "ImageIO",
        "Metal", "MetalKit", "MetalPerformanceShaders", "ModelIO",
        "SceneKit", "SpriteKit", "GameplayKit", "GameController",
        // Connectivity
        "Network", "CoreBluetooth", "MultipeerConnectivity", "WatchConnectivity",
        // Location / Maps
        "CoreLocation", "MapKit",
        // Health / Motion
        "HealthKit", "CoreMotion", "CoreHaptics",
        // ML / Vision
        "CoreML", "Vision", "NaturalLanguage", "SoundAnalysis", "CreateML",
        // Security
        "CryptoKit", "Security", "LocalAuthentication", "AuthenticationServices",
        // System
        "os", "OSLog", "Accelerate", "simd", "Compression", "SystemConfiguration",
        // C system modules
        "zlib", "CommonCrypto", "CCommonCrypto", "SQLite3",
        // Notifications / Background
        "UserNotifications", "BackgroundTasks", "PushKit",
        // Store / Payments
        "StoreKit", "PassKit",
        // Contacts / Calendar / Photos
        "Contacts", "ContactsUI", "EventKit", "EventKitUI",
        "Photos", "PhotosUI",
        // Web / Safari
        "WebKit", "SafariServices", "LinkPresentation",
        // AR / Reality
        "ARKit", "RealityKit", "RealityFoundation",
        // Activities / Widgets / Intents
        "ActivityKit", "WidgetKit", "AppIntents", "Intents", "IntentsUI",
        // New frameworks
        "Charts", "TipKit", "Spatial", "GroupActivities",
        "RegexBuilder", "Collections", "Algorithms",
        // Testing
        "XCTest", "Testing",
        // SPM
        "PackageDescription", "PackagePlugin",
        // Misc
        "UniformTypeIdentifiers", "CoreServices", "CoreFoundation",
        "CoreTelephony", "CoreSpotlight", "FileProvider",
        "PDFKit", "PencilKit", "VisionKit",
        "NotificationCenter", "ScreenCaptureKit",
        "DeviceActivity", "FamilyControls", "ManagedSettings",
        "Accessibility", "SwiftUICore",
    ]

    /// Extracts target names from a `Package.swift` content string.
    public static func extractTargetNames(from content: String) -> [String] {
        let pattern = #"\.(?:target|executableTarget|testTarget|plugin|systemLibrary|binaryTarget|macro)\s*\(\s*name:\s*"([^"]+)""#
        // silent: constant regex pattern
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)
        return matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[nameRange])
        }
    }

    /// Extracts `.product(name:` references from a `Package.swift` content string.
    public static func extractProductNames(from content: String) -> [String] {
        let pattern = #"\.product\s*\(\s*name:\s*"([^"]+)""#
        // silent: constant regex pattern
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)
        return matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[nameRange])
        }
    }

    /// Extracts import statements from a Swift source string.
    public static func extractImports(from source: String) -> [ImportStatement] {
        let importPattern = #"(?m)^\s*(?:@\w+\s+)*import\s+(\w+)"#
        let canImportPattern = #"(?m)^\s*#if\s+canImport\((\w+)\)"#

        // silent: constant regex patterns
        guard let importRegex = try? NSRegularExpression(pattern: importPattern, options: []),
              let canImportRegex = try? NSRegularExpression(pattern: canImportPattern, options: []) else { // silent: constant regex

            return []
        }

        let lines = source.components(separatedBy: .newlines)

        // Collect canImport module names and their line numbers
        var canImportGuards: [String: Set<Int>] = [:]
        let fullRange = NSRange(source.startIndex..., in: source)
        let canImportMatches = canImportRegex.matches(in: source, options: [], range: fullRange)
        for match in canImportMatches {
            guard match.numberOfRanges >= 2,
                  let moduleRange = Range(match.range(at: 1), in: source) else { continue }
            let moduleName = String(source[moduleRange])
            guard let matchRange = Range(match.range(at: 0), in: source) else { continue }
            let matchStart = matchRange.lowerBound
            let lineNumber = source[source.startIndex..<matchStart].filter { $0 == "\n" }.count + 1
            canImportGuards[moduleName, default: []].insert(lineNumber)
        }

        var imports: [ImportStatement] = []
        var inMultilineString = false
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            // Track multi-line string literal boundaries (""")
            let tripleQuoteCount = countOccurrences(of: "\"\"\"", in: line)
            if tripleQuoteCount > 0 {
                if tripleQuoteCount % 2 != 0 {
                    inMultilineString.toggle()
                }
                continue
            }
            guard !inMultilineString else { continue }

            let lineNSRange = NSRange(line.startIndex..., in: line)
            guard let match = importRegex.firstMatch(in: line, options: [], range: lineNSRange),
                  match.numberOfRanges >= 2,
                  let moduleRange = Range(match.range(at: 1), in: line) else { continue }

            let moduleName = String(line[moduleRange])

            // Check if guarded by canImport for the same module on a preceding line
            let isGuarded: Bool
            if let guardLines = canImportGuards[moduleName] {
                isGuarded = guardLines.contains(where: { $0 < lineNumber })
            } else {
                isGuarded = false
            }

            imports.append(ImportStatement(
                moduleName: moduleName,
                line: lineNumber,
                isCanImportGuarded: isGuarded
            ))
        }

        return imports
    }

    /// Checks source files for imports of modules not in the known set.
    public static func checkHallucinatedImports(
        sourceFiles: [(path: String, content: String)],
        knownModules: Set<String>
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        for (path, content) in sourceFiles {
            let imports = extractImports(from: content)
            for imp in imports {
                guard !imp.isCanImportGuarded else { continue }
                guard !knownModules.contains(imp.moduleName) else { continue }

                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Import '\(imp.moduleName)' not found in declared dependencies or system frameworks",
                    filePath: path,
                    lineNumber: imp.line,
                    ruleId: "dep-hallucinated-import"
                ))
            }
        }

        return diagnostics
    }

    /// Counts non-overlapping occurrences of a substring.
    private static func countOccurrences(of target: String, in string: String) -> Int {
        var count = 0
        var searchRange = string.startIndex..<string.endIndex
        while let range = string.range(of: target, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<string.endIndex
        }
        return count
    }

    /// Discovers all `Package.swift` files recursively, skipping build artifacts.
    static func discoverPackageManifests(in root: String) -> [String] {
        let fm = FileManager.default
        var results: [String] = []

        let skipDirs: Set<String> = [".build", "Packages", "checkouts", ".swiftpm", "DerivedData"]

        guard let enumerator = fm.enumerator(atPath: root) else { return [] }
        while let relativePath = enumerator.nextObject() as? String {
            let lastComponent = (relativePath as NSString).lastPathComponent

            // Skip directories that contain build artifacts
            let pathComponents = relativePath.components(separatedBy: "/")
            if pathComponents.contains(where: { skipDirs.contains($0) }) {
                continue
            }

            if lastComponent == "Package.swift" {
                results.append((root as NSString).appendingPathComponent(relativePath))
            }
        }

        return results
    }

    // MARK: - Status Computation

    /// Computes the overall check status from a set of diagnostics.
    ///
    /// - Parameter diagnostics: The collected diagnostics.
    /// - Returns: `.failed` if any errors, `.warning` if any warnings, `.passed` otherwise.
    static func computeStatus(from diagnostics: [Diagnostic]) -> CheckResult.Status {
        if diagnostics.contains(where: { $0.severity == .error }) {
            return .failed
        }
        if diagnostics.contains(where: { $0.severity == .warning }) {
            return .warning
        }
        return .passed
    }
}
