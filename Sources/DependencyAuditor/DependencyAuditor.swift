import Foundation
import QualityGateCore

// MARK: - Package.resolved Models

/// Represents the decoded contents of a `Package.resolved` file (v2/v3 format).
struct PackageResolved: Sendable, Codable {
    /// The array of pinned dependencies.
    let pins: [ResolvedPin]
    /// The format version of the resolved file.
    let version: Int?
}

/// A single pinned dependency in `Package.resolved`.
struct ResolvedPin: Sendable, Codable {
    /// The lowercased package identity (e.g. `"swift-syntax"`).
    let identity: String
    /// The kind of source control (e.g. `"remoteSourceControl"`).
    let kind: String?
    /// The repository URL.
    let location: String
    /// The resolved state — version, branch, or bare revision.
    let state: PinState
}

/// The resolution state of a single dependency pin.
struct PinState: Sendable, Codable {
    /// If the pin tracks a branch, the branch name; otherwise `nil`.
    let branch: String?
    /// The pinned Git revision hash.
    let revision: String?
    /// If the pin tracks a version tag, the semantic version string; otherwise `nil`.
    let version: String?
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
        var diagnostics: [Diagnostic] = []

        // --- dep-unresolved ---
        let resolvedPath = projectRoot + "/Package.resolved"
        let packageSwiftPath = projectRoot + "/Package.swift"
        let resolvedExists = FileManager.default.fileExists(atPath: resolvedPath) // SAFETY: reads local project file
        let packageSwiftContent = (try? String(contentsOfFile: packageSwiftPath, encoding: .utf8)) ?? ""
        let packageSwiftURLs = Self.extractPackageURLs(from: packageSwiftContent)

        var resolvedPinCount = 0
        var pins: [ResolvedPin] = []

        if resolvedExists {
            if let data = FileManager.default.contents(atPath: resolvedPath), // SAFETY: reads local project file
               let json = String(data: data, encoding: .utf8),
               let resolved = try? Self.parsePackageResolved(json) {
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

        let duration = start.duration(to: clock.now)
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
    /// Looks for `.package(url:` patterns and extracts the quoted URL argument.
    ///
    /// - Parameter content: The raw text of `Package.swift`.
    /// - Returns: An array of dependency URL strings.
    static func extractPackageURLs(from content: String) -> [String] {
        // Match .package(url: "...") patterns
        let pattern = #"\.package\(\s*url:\s*"([^"]+)""#
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

        guard fm.fileExists(atPath: workspaceStatePath),
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
