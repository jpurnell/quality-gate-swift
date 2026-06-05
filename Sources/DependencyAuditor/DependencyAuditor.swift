import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

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

    /// Extracts dependency URLs from `Package.swift` content via AST.
    ///
    /// Handles both `.package(url:` and `.package(name:, url:` formats.
    ///
    /// - Parameter content: The raw text of `Package.swift`.
    /// - Returns: An array of dependency URL strings.
    static func extractPackageURLs(from content: String) -> [String] {
        ManifestParser.parse(source: content).packageURLs
    }

    /// Extracts explicit package `name:` parameters from dependency declarations via AST.
    ///
    /// Handles `.package(name: "RxSwift", ...)` which declares the package identity.
    ///
    /// - Parameter content: The raw text of `Package.swift`.
    /// - Returns: An array of declared package names.
    static func extractPackageDeclaredNames(from content: String) -> [String] { // LIVE: called from DependencyAuditorTests
        ManifestParser.parse(source: content).declaredNames
    }

    /// Extracts target `exclude:` paths from a `Package.swift` content string via AST.
    static func extractExcludePaths(from content: String) -> [String] { // LIVE: called from DependencyAuditorTests
        ManifestParser.parse(source: content).excludePaths
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

        // Parse root manifest once via AST
        let rootInfo = ManifestParser.parse(source: packageSwiftContent)
        knownModules.formUnion(rootInfo.targetNames)
        knownModules.formUnion(rootInfo.productNames)
        knownModules.formUnion(rootInfo.declaredNames)
        addURLDerivedNames(from: rootInfo.packageURLs, into: &knownModules)

        // Parse all discovered sub-manifests once each (monorepo support)
        let manifests = discoverPackageManifests(in: projectRoot)
        var manifestInfos: [(path: String, info: ManifestParser.ManifestInfo)] = []
        for manifestPath in manifests {
            // silent: unreadable manifest files skipped gracefully
            guard let content = try? String(contentsOfFile: manifestPath, encoding: .utf8) else { continue }
            let info = ManifestParser.parse(source: content)
            manifestInfos.append((path: manifestPath, info: info))
            knownModules.formUnion(info.targetNames)
            knownModules.formUnion(info.productNames)
            knownModules.formUnion(info.declaredNames)
            addURLDerivedNames(from: info.packageURLs, into: &knownModules)
        }

        // Add package identities and derived names from Package.resolved
        for pin in pins {
            addPinDerivedNames(pin: pin, into: &knownModules)
        }

        // Also scan Package.resolved files in subdirectories (monorepo)
        for (manifestPath, _) in manifestInfos {
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

        // Scan .build/checkouts/ for dependency-vended products and targets
        let checkoutsDir = (projectRoot as NSString).appendingPathComponent(".build/checkouts")
        // silent: missing .build/checkouts is expected when dependencies aren't resolved yet
        if let checkoutEntries = try? fm.contentsOfDirectory(atPath: checkoutsDir) { // SAFETY: CLI tool reads local .build/checkouts
            for entry in checkoutEntries {
                let depManifest = (checkoutsDir as NSString)
                    .appendingPathComponent(entry)
                    .appending("/Package.swift")
                // silent: unreadable checkout manifests skipped gracefully
                guard let content = try? String(contentsOfFile: depManifest, encoding: .utf8) else { continue }
                let info = ManifestParser.parse(source: content)
                knownModules.formUnion(info.productNames)
                knownModules.formUnion(info.targetNames)
            }
        }

        // Add user-configured additional modules
        knownModules.formUnion(config.additionalKnownModules)

        // Discover source files from each package's Sources/ and Tests/ directories,
        // respecting exclude: paths from the already-parsed manifests
        var sourceFiles: [(path: String, content: String)] = []

        // Build (root, excludePaths) pairs from parsed manifests
        var packageExcludes: [(root: String, excludePaths: [String])] = []
        if !packageSwiftContent.isEmpty {
            packageExcludes.append((root: projectRoot, excludePaths: rootInfo.excludePaths))
        }
        for (manifestPath, info) in manifestInfos {
            let packageDir = (manifestPath as NSString).deletingLastPathComponent
            if packageDir != projectRoot {
                packageExcludes.append((root: packageDir, excludePaths: info.excludePaths))
            }
        }

        for (packageRoot, excludePaths) in packageExcludes {
            for dir in ["Sources", "Tests"] {
                let dirPath = (packageRoot as NSString).appendingPathComponent(dir)
                guard let enumerator = fm.enumerator(atPath: dirPath) else { continue }
                while let relativePath = enumerator.nextObject() as? String {
                    guard relativePath.hasSuffix(".swift") else { continue }

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

    /// Adds URL-derived module names from pre-extracted package URLs.
    private static func addURLDerivedNames(from urls: [String], into modules: inout Set<String>) {
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

    /// Extracts target names from a `Package.swift` content string via AST.
    public static func extractTargetNames(from content: String) -> [String] {
        ManifestParser.parse(source: content).targetNames
    }

    /// Extracts product names (`.library`, `.executable`, `.plugin`, `.product`) from a `Package.swift` content string via AST.
    public static func extractProductNames(from content: String) -> [String] {
        ManifestParser.parse(source: content).productNames
    }

    /// Extracts import statements from a Swift source string via AST.
    public static func extractImports(from source: String) -> [ImportStatement] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "", tree: tree)
        let visitor = ImportVisitor(converter: converter)
        visitor.walk(tree)
        return visitor.imports
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

// MARK: - AST-based Import Extraction

private final class ImportVisitor: SyntaxVisitor {
    let converter: SourceLocationConverter
    private(set) var imports: [DependencyAuditor.ImportStatement] = []
    private var canImportGuards: [String: [Int]] = [:]

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        if let condition = node.condition {
            for moduleName in findCanImportModules(in: Syntax(condition)) {
                let line = node.startLocation(converter: converter).line
                canImportGuards[moduleName, default: []].append(line)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let firstComponent = node.path.first else { return .skipChildren }
        let moduleName = firstComponent.name.text
        let line = node.startLocation(converter: converter).line

        let isGuarded = canImportGuards[moduleName]?.contains(where: { $0 < line }) ?? false

        imports.append(DependencyAuditor.ImportStatement(
            moduleName: moduleName,
            line: line,
            isCanImportGuarded: isGuarded
        ))
        return .skipChildren
    }

    private func findCanImportModules(in syntax: Syntax) -> [String] {
        var modules: [String] = []
        if let funcCall = syntax.as(FunctionCallExprSyntax.self),
           let callee = funcCall.calledExpression.as(DeclReferenceExprSyntax.self),
           callee.baseName.text == "canImport",
           let firstArg = funcCall.arguments.first {
            modules.append(firstArg.expression.trimmedDescription)
        }
        for child in syntax.children(viewMode: .sourceAccurate) {
            modules.append(contentsOf: findCanImportModules(in: child))
        }
        return modules
    }
}
