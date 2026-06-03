import Foundation
import QualityGateCore
import IndexStoreInfra

/// Audits Apple App Intents declarations for completeness,
/// discoverability, and Apple Intelligence readiness.
///
/// Uses a two-pass architecture:
/// - **Pass 1:** Per-file SwiftSyntax AST analysis (always runs)
/// - **Pass 2:** IndexStoreDB cross-file analysis (when index store is available)
public struct AppIntentsAuditor: QualityChecker, Sendable {
    /// Unique identifier for this auditor.
    public let id = "appintents-readiness"
    /// Human-readable display name for this auditor.
    public let name = "App Intents Readiness Auditor"

    /// Creates a new App Intents readiness auditor.
    public init() {}

    /// Runs App Intents readiness checks and returns diagnostics.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now
        let config = configuration.appIntentsReadiness

        guard config.enabled else {
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [],
                duration: ContinuousClock.now - start
            )
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let swiftFiles = SourceWalker.swiftFiles(
            under: root,
            excludePatterns: config.excludePaths
        )

        let appIntentFiles = swiftFiles.filter { path in
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return false } // silent: skip unreadable files during filtering
            return contents.contains("import AppIntents")
        }

        guard !appIntentFiles.isEmpty else {
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [],
                duration: ContinuousClock.now - start
            )
        }

        var diagnostics: [Diagnostic] = []

        for file in appIntentFiles {
            guard let source = try? String(contentsOfFile: file, encoding: .utf8) else { continue } // silent: skip unreadable files during analysis
            diagnostics.append(contentsOf: AppIntentVisitor.analyze(source: source, fileName: file))
        }

        let duration = ContinuousClock.now - start
        let hasError = diagnostics.contains { $0.severity == .error }
        let hasWarning = diagnostics.contains { $0.severity == .warning }
        let status: CheckResult.Status = hasError ? .failed : (hasWarning ? .warning : .passed)

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }
}
