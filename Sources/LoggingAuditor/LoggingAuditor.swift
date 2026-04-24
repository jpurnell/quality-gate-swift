import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source for logging hygiene issues in application projects.
///
/// Detected rules:
/// - `logging.print-statement`: `print()` in production code (use os.Logger)
/// - `logging.silent-try`: `try?` without adjacent error logging
/// - `logging.no-os-logger-import`: File uses print/NSLog without `import os`
///
/// This auditor is gated by `projectType` in configuration. When set to
/// `"library"`, the auditor returns `.skipped` immediately — libraries
/// intentionally strip logging, and consumers decide what to log.
public struct LoggingAuditor: QualityChecker, Sendable {
    public let id = "logging"
    public let name = "Logging Auditor"

    private let config: LoggingAuditorConfig

    public init(config: LoggingAuditorConfig = .default) {
        self.config = config
    }

    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        // Libraries skip logging checks entirely
        guard config.projectType == "application" else {
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [],
                duration: ContinuousClock.now - startTime
            )
        }

        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []
        if fileManager.fileExists(atPath: sourcesPath) {
            allDiagnostics.append(contentsOf: try await auditDirectory(at: sourcesPath, configuration: configuration))
        }

        let duration = ContinuousClock.now - startTime

        // Error = failed, warning-only = warning, clean = passed
        let hasError = allDiagnostics.contains { $0.severity == .error }
        let hasWarning = allDiagnostics.contains { $0.severity == .warning }
        let status: CheckResult.Status
        if hasError {
            status = .failed
        } else if hasWarning {
            status = .warning
        } else {
            status = .passed
        }

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            duration: duration
        )
    }

    /// Single-file audit for testing.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        guard config.projectType == "application" else {
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [],
                duration: ContinuousClock.now - startTime
            )
        }

        let diagnostics = auditSourceCode(source, fileName: fileName)
        let duration = ContinuousClock.now - startTime

        let hasError = diagnostics.contains { $0.severity == .error }
        let hasWarning = diagnostics.contains { $0.severity == .warning }
        let status: CheckResult.Status
        if hasError {
            status = .failed
        } else if hasWarning {
            status = .warning
        } else {
            status = .passed
        }

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    // MARK: - Private

    private func auditDirectory(
        at path: String,
        configuration: Configuration
    ) async throws -> [Diagnostic] {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        guard let enumerator = fileManager.enumerator(atPath: path) else { return [] }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            // Skip test files
            if relativePath.contains("Tests") { continue }

            // Skip excluded patterns
            let excluded = configuration.excludePatterns.contains { pattern in
                relativePath.contains(pattern.replacingOccurrences(of: "**/", with: "")
                    .replacingOccurrences(of: "/**", with: ""))
            }
            if excluded { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                diagnostics.append(contentsOf: auditSourceCode(source, fileName: fullPath))
            } catch {
                continue
            }
        }
        return diagnostics
    }

    private func auditSourceCode(_ source: String, fileName: String) -> [Diagnostic] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let sourceLines = source.components(separatedBy: "\n")
        let visitor = LoggingVisitor(
            fileName: fileName,
            converter: converter,
            sourceLines: sourceLines,
            silentTryKeyword: config.silentTryKeyword,
            allowedSilentTryFunctions: Set(config.allowedSilentTryFunctions),
            customLoggerNames: config.customLoggerNames
        )
        visitor.walk(tree)
        return visitor.diagnostics
    }
}
