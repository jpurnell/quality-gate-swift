import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Enforces Apple Human Interface Guidelines compliance for SwiftUI apps.
///
/// Checks SwiftUI source files for platform-appropriate patterns including
/// menu bar commands, keyboard shortcuts, navigation patterns, tooltips,
/// context menus, semantic colors, and more.
///
/// ## Usage
///
/// ```swift
/// import QualityGateCore
///
/// let config = Configuration()
/// let auditor = HIGAuditor()
/// let result = try await auditor.check(configuration: config)
/// ```
///
/// ## Exemptions
///
/// Suppress individual findings with an inline comment:
/// ```swift
/// import SwiftUI
///
/// struct UtilityWindow: View {
///     var body: some View {
///         // HIG-EXEMPT: single-purpose utility window
///         NavigationStack { Text("Utility") }
///     }
/// }
/// ```
public struct HIGAuditor: FixableChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "HIGAuditor")

    /// Unique identifier for this checker.
    public let id = "hig-auditor"
    /// Human-readable display name for this checker.
    public let name = "HIG Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Apple Human Interface Guidelines compliance for SwiftUI views"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.safetySecurity

    /// What this checker's findings are about — see `CheckerKind`.
    ///
    /// `convention`, not `code`. The standard is Apple's rather than this project's, but it is
    /// still a convention: a CLI tool, a deliberately unconventional interface, or an app
    /// targeting a different design language is not *defective* for departing from the HIG.
    /// Reported against a repository nobody here owns, these findings are an opinion about
    /// someone's design decisions — the same reason `context` sits here despite scanning
    /// source.
    public let kind = CheckerKind.convention

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly
    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Describes the auto-fix behavior applied by this checker.
    public let fixDescription = "Inserts TODO-marked HIG scaffolding (Settings scene, .commands, .help, .contextMenu)."

    private let platformOverride: HIGPlatform?

    /// Creates an auditor, optionally targeting specific platforms instead of auto-detecting.
    public init(platforms: HIGPlatform? = nil) {
        self.platformOverride = platforms
    }

    // MARK: - QualityChecker

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
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Audits all Swift sources under `Sources/` for HIG compliance issues.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let root = configuration.resolvedProjectRoot
        let currentDir = root.path
        // Hardcoded `Sources/` before this — and the SAFETY comment said "relative Sources/
        // under cwd", which had already stopped being true when the root was threaded through
        // configuration. `SourceWalker` owns the exclusion decision now.
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)

        let activePlatforms = platformOverride
            ?? PlatformDetector.detectFromPackageManifest(at: currentDir)

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []

        let result = try await auditFiles(
            scan.files,
            activePlatforms: activePlatforms,
            configuration: configuration
        )
        allDiagnostics.append(contentsOf: result.diagnostics)
        allOverrides.append(contentsOf: result.overrides)

        // Emitted pass or fail — examined-nothing must not look like found-nothing.
        let plural = scan.files.count == 1 ? "" : "s"
        allDiagnostics.append(Diagnostic(
            severity: .note,
            message: "hig examined \(scan.files.count) file\(plural)"
                + (scan.exclusionClause.map { " · \($0)" } ?? ""),
            ruleId: "hig-auditor.coverage"))

        let duration = ContinuousClock.now - startTime
        // Notes excluded: the coverage note above is a diagnostic, and an `isEmpty` test would
        // fail every run the moment it was added.
        let status: CheckResult.Status = allDiagnostics.contains { $0.severity != .note } ? .failed : .passed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            overrides: allOverrides,
            duration: duration
        )
    }

    // MARK: - FixableChecker

    /// Applies automatic scaffolding fixes for the given HIG diagnostics.
    public func fix(
        diagnostics: [Diagnostic],
        configuration: Configuration
    ) async throws -> FixResult {
        var modifications: [FileModification] = []
        var unfixed: [Diagnostic] = []

        let grouped = Dictionary(grouping: diagnostics, by: { $0.filePath ?? "" })

        for (filePath, fileDiagnostics) in grouped {
            guard !filePath.isEmpty else {
                unfixed.append(contentsOf: fileDiagnostics)
                continue
            }

            var source: String
            do {
                source = try String(contentsOfFile: filePath, encoding: .utf8)
            } catch {
                Self.logger.warning("File unreadable during fix pass: \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                unfixed.append(contentsOf: fileDiagnostics)
                continue
            }

            var linesChanged = 0
            var sourceModified = false

            for diagnostic in fileDiagnostics.sorted(by: { ($0.lineNumber ?? 0) > ($1.lineNumber ?? 0) }) {
                guard let ruleId = diagnostic.ruleId else {
                    unfixed.append(diagnostic)
                    continue
                }

                let fixed = applyFix(ruleId: ruleId, source: &source, diagnostic: diagnostic)
                if fixed {
                    linesChanged += 1
                    sourceModified = true
                } else {
                    unfixed.append(diagnostic)
                }
            }

            if sourceModified {
                try source.write(toFile: filePath, atomically: true, encoding: .utf8)
                modifications.append(FileModification(
                    filePath: filePath,
                    description: "Applied HIG auto-fixes",
                    linesChanged: linesChanged
                ))
            }
        }

        return FixResult(modifications: modifications, unfixed: unfixed)
    }

    // MARK: - Public API for Testing

    /// Audit a single source code string.
    public func auditSource(
        _ source: String,
        fileName: String,
        activePlatforms: HIGPlatform
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        guard source.contains("import SwiftUI") else {
            return ([], [])
        }

        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let sourceLines = source.lines

        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        let hasAppConformance = source.contains(": App")
        let hasViewConformance = source.contains(": View")

        if hasAppConformance {
            // A file that names its own platform outranks the project-wide default,
            // which is `.all` for any repo without a Package.swift at its root.
            let appPlatforms = PlatformDetector.detectAppPlatform(source) ?? activePlatforms
            let appVisitor = AppStructureVisitor(
                fileName: fileName,
                converter: converter,
                sourceLines: sourceLines,
                activePlatforms: appPlatforms
            )
            appVisitor.walk(tree)
            diagnostics.append(contentsOf: appVisitor.diagnostics)
            overrides.append(contentsOf: appVisitor.overrides)
        }

        if hasViewConformance || hasAppConformance {
            let navVisitor = NavigationPatternVisitor(
                fileName: fileName,
                converter: converter,
                sourceLines: sourceLines,
                activePlatforms: activePlatforms
            )
            navVisitor.walk(tree)
            diagnostics.append(contentsOf: navVisitor.diagnostics)
            overrides.append(contentsOf: navVisitor.overrides)

            let modifierVisitor = ViewModifierVisitor(
                fileName: fileName,
                converter: converter,
                sourceLines: sourceLines,
                activePlatforms: activePlatforms
            )
            modifierVisitor.walk(tree)
            diagnostics.append(contentsOf: modifierVisitor.diagnostics)
            overrides.append(contentsOf: modifierVisitor.overrides)
        }

        return (diagnostics, overrides)
    }

    // MARK: - Private

    /// Audits an already-scoped list of Swift files; the walk decides what the run owns.
    private func auditFiles(
        _ paths: [String],
        activePlatforms: HIGPlatform,
        configuration: Configuration
    ) async throws -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        for fullPath in paths {
            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let result = auditSource(source, fileName: fullPath, activePlatforms: activePlatforms)
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
            } catch {
                Self.logger.warning("Failed to read source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        return (diagnostics, overrides)
    }

    private func applyFix(ruleId: String, source: inout String, diagnostic: Diagnostic) -> Bool {
        switch ruleId {
        case HIGRules.settingsScene.id:
            return insertSettingsScene(source: &source)
        case HIGRules.menuCommands.id:
            return insertCommandsModifier(source: &source)
        case HIGRules.toolbarTooltips.id:
            return insertHelpModifier(source: &source, at: diagnostic.lineNumber)
        case HIGRules.contextMenus.id:
            return insertContextMenu(source: &source, at: diagnostic.lineNumber)
        default:
            return false
        }
    }

    private func insertSettingsScene(source: inout String) -> Bool {
        guard let range = source.range(of: "WindowGroup") else { return false }

        var braceCount = 0
        var searchStart = range.upperBound
        var foundClosingBrace = false

        while searchStart < source.endIndex {
            let char = source[searchStart]
            if char == "{" { braceCount += 1 }
            if char == "}" {
                braceCount -= 1
                if braceCount == 0 {
                    foundClosingBrace = true
                    break
                }
            }
            searchStart = source.index(after: searchStart)
        }

        guard foundClosingBrace else { return false }

        let insertionPoint = source.index(after: searchStart)
        source.insert(contentsOf: "\n        Settings { Text(\"TODO: Settings\") }", at: insertionPoint)
        return true
    }

    private func insertCommandsModifier(source: inout String) -> Bool {
        guard let range = source.range(of: "WindowGroup") else { return false }

        var braceCount = 0
        var searchStart = range.upperBound
        var foundClosingBrace = false

        while searchStart < source.endIndex {
            let char = source[searchStart]
            if char == "{" { braceCount += 1 }
            if char == "}" {
                braceCount -= 1
                if braceCount == 0 {
                    foundClosingBrace = true
                    break
                }
            }
            searchStart = source.index(after: searchStart)
        }

        guard foundClosingBrace else { return false }

        let insertionPoint = source.index(after: searchStart)
        let commandsBlock = """
        \n        .commands {
                    CommandGroup(replacing: .newItem) { /* TODO: Add menu commands */ }
                }
        """
        source.insert(contentsOf: commandsBlock, at: insertionPoint)
        return true
    }

    private func insertHelpModifier(source: inout String, at lineNumber: Int?) -> Bool {
        guard let lineNumber else { return false }
        var lines = source.lines
        guard lineNumber >= 1, lineNumber <= lines.count else { return false }

        let line = lines[lineNumber - 1]
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        lines.insert("\(indent)    .help(\"TODO: describe action\")", at: lineNumber)
        source = lines.joined(separator: "\n")
        return true
    }

    private func insertContextMenu(source: inout String, at lineNumber: Int?) -> Bool {
        guard let lineNumber else { return false }
        var lines = source.lines
        guard lineNumber >= 1, lineNumber <= lines.count else { return false }

        let line = lines[lineNumber - 1]
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        lines.insert("\(indent)    .contextMenu { /* TODO: Add context actions */ }", at: lineNumber)
        source = lines.joined(separator: "\n")
        return true
    }
}
