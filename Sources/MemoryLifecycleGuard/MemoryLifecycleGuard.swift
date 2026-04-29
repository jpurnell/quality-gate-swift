import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source for memory lifecycle issues that can cause leaks or dangling tasks.
///
/// Detected rules:
/// - `lifecycle-task-no-deinit` — Class has stored `Task` property but no `deinit`
/// - `lifecycle-task-no-cancel` — Class has stored `Task` property and `deinit` that omits `.cancel()`
/// - `lifecycle-strong-delegate` — Stored property matching a delegate pattern is not `weak`/`unowned`
public struct MemoryLifecycleGuard: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "memory-lifecycle"
    /// Human-readable display name for this checker.
    public let name = "Memory Lifecycle Guard"

    /// Creates a new memory lifecycle guard.
    public init() {}

    /// Audits all Swift source files under the `Sources/` directory for memory lifecycle violations.
    ///
    /// Files in the `Tests/` directory and files matching `configuration.memoryLifecycle.exemptFiles`
    /// are skipped. Actor declarations are exempt from all rules.
    ///
    /// - Parameter configuration: Project-specific configuration.
    /// - Returns: The check result with status and diagnostics.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")
        let config = configuration.memoryLifecycle

        var allDiagnostics: [Diagnostic] = []

        if fileManager.fileExists(atPath: sourcesPath) {
            allDiagnostics = auditDirectory(at: sourcesPath, config: config)
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .warning
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            duration: duration
        )
    }

    // MARK: - Private

    private func auditDirectory(
        at path: String,
        config: MemoryLifecycleConfig
    ) -> [Diagnostic] {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        guard let enumerator = fileManager.enumerator(atPath: path) else { return [] }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            // Skip test files
            guard !relativePath.contains("Tests/") else { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            // Skip exempt files
            let isExempt = config.exemptFiles.contains { exemptPattern in
                fullPath.contains(exemptPattern)
            }
            guard !isExempt else { continue }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let fileDiags = auditSourceCode(source, fileName: fullPath, config: config)
                diagnostics.append(contentsOf: fileDiags)
            } catch {
                continue
            }
        }
        return diagnostics
    }

    private func auditSourceCode(
        _ source: String,
        fileName: String,
        config: MemoryLifecycleConfig
    ) -> [Diagnostic] {
        let tree = Parser.parse(source: source)
        let visitor = LifecycleVisitor(
            filePath: fileName,
            source: source,
            config: config,
            tree: tree
        )
        visitor.walk(tree)
        return visitor.diagnostics
    }
}
