import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
import AccessibilityCore
import AccessibilitySwiftUI
import AccessibilityCLI
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Audits source files for accessibility violations across UI frontends.
///
/// This is the orchestrator: for each source file it resolves which UI frontend(s)
/// apply (via `FrontendResolver`), then runs the matching `AccessibilityDetector`s
/// and collects their diagnostics. Today the SwiftUI detector is wired in; CLI and other
/// frontends plug into the same dispatch.
///
/// ## Rules (SwiftUI)
///
/// - `a11y.swiftui.fixed-font-size`: `.font(.system(size:))` instead of semantic text styles
/// - `a11y.swiftui.missing-reduce-motion`: `withAnimation` / `.animation()` without `accessibilityReduceMotion` check
/// - `a11y.swiftui.missing-accessibility-label`: `Image` without `.accessibilityLabel()`
public struct AccessibilityAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "AccessibilityAuditor")

    /// Unique identifier for this checker.
    public let id = "accessibility"

    /// Human-readable name for this checker.
    public let name = "Accessibility Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "SwiftUI accessibility: missing labels, fixed font sizes, color-only differentiation"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.codeHygiene

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// The per-frontend detectors this auditor dispatches to.
    private let detectors: [any AccessibilityDetector]

    /// Creates a new AccessibilityAuditor instance.
    public init() {
        self.detectors = [SwiftUIAccessibilityDetector(), CLIAccessibilityDetector()]
    }

    /// Declares this checker cacheable on the source tree it reads.
    ///
    /// Syntactic analysis over the sources, with no clock, corpus, network or out-of-tree path
    /// among its inputs — so the same tree under the same gate binary yields the same verdict.
    /// `gateIdentityHash` folds in the binary's identity and the toolchain, so a rebuild or a
    /// compiler change invalidates every entry.
    ///
    /// `wholeSourceAndDocs` rather than `wholeSource`: it is the wider set, and over-including
    /// an input costs a cache miss while under-including one serves a stale pass.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndDocs(
            projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            configuration: configuration
        )
    }

    /// Run the accessibility audit on the current directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []

        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project sources
            let result = try await auditDirectory(
                at: sourcesPath,
                configuration: configuration
            )
            allDiagnostics.append(contentsOf: result.diagnostics)
            allOverrides.append(contentsOf: result.overrides)
        }

        let duration = ContinuousClock.now - startTime
        let hasErrors = allDiagnostics.contains { $0.severity == .error }
        let status: CheckResult.Status = hasErrors ? .failed : (allDiagnostics.isEmpty ? .passed : .warning)

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            overrides: allOverrides,
            duration: duration
        )
    }

    /// Audit a single source code string.
    ///
    /// - Parameters:
    ///   - source: The Swift source code to audit.
    ///   - fileName: The name of the file (for diagnostics).
    ///   - configuration: The project configuration.
    /// - Returns: A check result with any violations found.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration = Configuration()
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let result = auditSourceCode(source, fileName: fileName, configuration: configuration)

        let duration = ContinuousClock.now - startTime
        let hasErrors = result.diagnostics.contains { $0.severity == .error }
        let status: CheckResult.Status = hasErrors ? .failed : (result.diagnostics.isEmpty ? .passed : .warning)

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: result.diagnostics,
            overrides: result.overrides,
            duration: duration
        )
    }

    // MARK: - Private Implementation

    private func auditDirectory(
        at path: String,
        configuration: Configuration
    ) async throws -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return ([], [])
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            if shouldExclude(path: fullPath, patterns: configuration.excludePatterns) {
                continue
            }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let result = auditSourceCode(source, fileName: fullPath, configuration: configuration)
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
            } catch {
                Self.logger.warning("Failed to read source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        return (diagnostics, overrides)
    }

    private func shouldExclude(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if pathMatches(path: path, pattern: pattern) {
                return true
            }
        }
        return false
    }

    private func pathMatches(path: String, pattern: String) -> Bool {
        if pattern.contains("**") {
            let component = pattern.replacingOccurrences(of: "**/", with: "")
                .replacingOccurrences(of: "/**", with: "")
            return path.contains(component)
        }
        return path.contains(pattern.replacingOccurrences(of: "*", with: ""))
    }

    private func auditSourceCode(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let frontends = FrontendResolver.resolve(importedModules: Self.importedModules(in: source))
        guard !frontends.isEmpty else { return ([], []) }

        let unit = SourceUnit(
            fileName: fileName,
            source: source,
            exemptionPatterns: configuration.safetyExemptions
        )

        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        for detector in detectors where frontends.contains(detector.frontend) {
            let result = detector.detect(in: unit)
            diagnostics.append(contentsOf: result.diagnostics)
            overrides.append(contentsOf: result.overrides)
        }
        return (diagnostics, overrides)
    }

    /// Extracts the set of imported module names from a Swift source file.
    private static func importedModules(in source: String) -> Set<String> {
        let tree = Parser.parse(source: source)
        var modules: Set<String> = []
        for statement in tree.statements {
            guard let importDecl = statement.item.as(ImportDeclSyntax.self),
                  let first = importDecl.path.first else {
                continue
            }
            modules.insert(first.name.text)
        }
        return modules
    }
}
