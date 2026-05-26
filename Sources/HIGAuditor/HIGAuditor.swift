import Foundation
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
/// let auditor = HIGAuditor()
/// let result = try await auditor.check(configuration: config)
/// ```
///
/// ## Exemptions
///
/// Suppress individual findings with an inline comment:
/// ```swift
/// // HIG-EXEMPT: single-purpose utility window
/// NavigationStack { UtilityView() }
/// ```
public struct HIGAuditor: FixableChecker, Sendable {
    public let id = "hig-auditor"
    public let name = "HIG Auditor"
    public let fixDescription = "Inserts TODO-marked HIG scaffolding (Settings scene, .commands, .help, .contextMenu)."

    private let platformOverride: HIGPlatform?

    public init(platforms: HIGPlatform? = nil) {
        self.platformOverride = platforms
    }

    // MARK: - QualityChecker

    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        let activePlatforms = platformOverride
            ?? PlatformDetector.detectFromPackageManifest(at: currentDir)

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []

        if fileManager.fileExists(atPath: sourcesPath) {
            let result = try await auditDirectory(
                at: sourcesPath,
                activePlatforms: activePlatforms,
                configuration: configuration
            )
            allDiagnostics.append(contentsOf: result.diagnostics)
            allOverrides.append(contentsOf: result.overrides)
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .failed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            overrides: allOverrides,
            duration: duration
        )
    }

    // MARK: - FixableChecker

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

            guard var source = try? String(contentsOfFile: filePath, encoding: .utf8) else {
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
        let sourceLines = source.components(separatedBy: "\n")

        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        let hasAppConformance = source.contains(": App")
        let hasViewConformance = source.contains(": View")

        if hasAppConformance {
            let appVisitor = AppStructureVisitor(
                fileName: fileName,
                converter: converter,
                sourceLines: sourceLines,
                activePlatforms: activePlatforms
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

    private func auditDirectory(
        at path: String,
        activePlatforms: HIGPlatform,
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
                let result = auditSource(source, fileName: fullPath, activePlatforms: activePlatforms)
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
            } catch {
                continue
            }
        }

        return (diagnostics, overrides)
    }

    private func shouldExclude(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if path.contains(pattern) {
                return true
            }
        }
        return false
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
        var lines = source.components(separatedBy: "\n")
        guard lineNumber >= 1, lineNumber <= lines.count else { return false }

        let line = lines[lineNumber - 1]
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        lines.insert("\(indent)    .help(\"TODO: describe action\")", at: lineNumber)
        source = lines.joined(separator: "\n")
        return true
    }

    private func insertContextMenu(source: inout String, at lineNumber: Int?) -> Bool {
        guard let lineNumber else { return false }
        var lines = source.components(separatedBy: "\n")
        guard lineNumber >= 1, lineNumber <= lines.count else { return false }

        let line = lines[lineNumber - 1]
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        lines.insert("\(indent)    .contextMenu { /* TODO: Add context actions */ }", at: lineNumber)
        source = lines.joined(separator: "\n")
        return true
    }
}
