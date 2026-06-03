import Foundation
import IndexStoreInfra
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source for memory lifecycle issues that can cause leaks or dangling tasks.
///
/// Detected rules:
/// - `lifecycle-task-no-deinit` — Class has stored `Task` property but no `deinit`
/// - `lifecycle-task-no-cancel` — Class has stored `Task` property and `deinit` that omits `.cancel()`
/// - `lifecycle-strong-delegate` — Stored property matching a delegate pattern is not `weak`/`unowned`
/// - `lifecycle-unbounded-stream` — `AsyncStream.makeStream()` without explicit `bufferingPolicy`
public struct MemoryLifecycleGuard: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "memory-lifecycle"
    /// Human-readable display name for this checker.
    public let name = "Memory Lifecycle Guard"

    /// Creates a new memory lifecycle guard.
    public init() {}

    /// Audits all Swift source files under the `Sources/` directory for memory lifecycle violations.
    ///
    /// Runs Pass 1 (syntactic) unconditionally, then attempts Pass 2 (index-backed)
    /// if `configuration.memoryLifecycle.useIndexStore` is true. Pass 2 degrades
    /// gracefully — a missing or stale index store never fails the quality gate.
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
        var allTaskInfos: [LifecycleIndexPass.TaskPropertyInfo] = []
        var allDelegateInfos: [LifecycleIndexPass.DelegatePropertyInfo] = []
        var allStreamInfos: [LifecycleIndexPass.StreamCreationInfo] = []

        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project Sources directory
            let result = auditDirectory(at: sourcesPath, config: config)
            allDiagnostics = result.diagnostics
            allTaskInfos = result.taskInfos
            allDelegateInfos = result.delegateInfos
            allStreamInfos = result.streamInfos
        }

        if config.useIndexStore && !allDiagnostics.isEmpty {
            do {
                let pass2Diagnostics = try runIndexPass(
                    pass1Diagnostics: allDiagnostics,
                    taskProperties: allTaskInfos,
                    delegateProperties: allDelegateInfos,
                    streamCreationSites: allStreamInfos
                )
                allDiagnostics = pass2Diagnostics
            } catch {
                allDiagnostics.append(Diagnostic(
                    severity: .note,
                    message: "Memory Lifecycle Pass 2 skipped: \(error.localizedDescription)",
                    ruleId: "lifecycle.index-pass.skipped"
                ))
            }
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.contains(where: { $0.severity == .warning }) ? .warning : .passed
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            duration: duration
        )
    }

    // MARK: - Pass 2 (index-backed)

    private func runIndexPass(
        pass1Diagnostics: [Diagnostic],
        taskProperties: [LifecycleIndexPass.TaskPropertyInfo],
        delegateProperties: [LifecycleIndexPass.DelegatePropertyInfo],
        streamCreationSites: [LifecycleIndexPass.StreamCreationInfo]
    ) throws -> [Diagnostic] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let kind = ProjectKind.detect(at: cwd)

        guard let located = try StoreLocator.locate(projectKind: kind) else {
            return pass1Diagnostics + [LifecycleIndexPass.unavailableNote()]
        }

        guard let libPath = IndexStoreSession.findLibIndexStore() else {
            return pass1Diagnostics + [LifecycleIndexPass.unavailableNote()]
        }

        let session = try IndexStoreSession(storePath: located.url, libPath: libPath)

        // Resolve cross-file cancel sites for task properties.
        var cancelSites: [LifecycleIndexPass.CancelSite] = []
        for taskProp in taskProperties {
            let refs = ConformanceQuery.findReferences(
                toUSR: taskProp.propertyName,
                in: session,
                roles: [.call, .reference]
            )
            for ref in refs where ref.filePath != taskProp.filePath {
                cancelSites.append(LifecycleIndexPass.CancelSite(
                    typeName: taskProp.typeName,
                    propertyName: taskProp.propertyName,
                    filePath: ref.filePath,
                    line: ref.line
                ))
            }
        }

        // Resolve cross-file stream termination sites.
        var terminationSites: [LifecycleIndexPass.StreamTerminationSite] = []
        let sourceFiles = SourceWalker.swiftFiles(under: cwd)
        let allSymbols = ConformanceQuery.symbolsInFiles(sourceFiles, in: session)
        for sym in allSymbols {
            if sym.symbol.name == "finish" || sym.symbol.name == "onTermination" {
                for streamSite in streamCreationSites where sym.filePath != streamSite.filePath {
                    terminationSites.append(LifecycleIndexPass.StreamTerminationSite(
                        variableName: streamSite.variableName,
                        filePath: sym.filePath,
                        line: 0
                    ))
                }
            }
        }

        // Run the pure analysis functions.
        var diagnostics = LifecycleIndexPass.analyzeTaskCancellation(
            pass1Diagnostics: pass1Diagnostics,
            taskProperties: taskProperties,
            cancelSitesInOtherFiles: cancelSites
        )

        let delegateDiags = LifecycleIndexPass.analyzeDelegateRetention(
            delegateProperties: delegateProperties,
            assignmentSites: []
        )
        diagnostics.append(contentsOf: delegateDiags)

        diagnostics = LifecycleIndexPass.analyzeStreamTermination(
            pass1Diagnostics: diagnostics,
            streamCreationSites: streamCreationSites,
            terminationSitesInOtherFiles: terminationSites
        )

        return diagnostics
    }

    // MARK: - Private

    private struct AuditResult {
        let diagnostics: [Diagnostic]
        let taskInfos: [LifecycleIndexPass.TaskPropertyInfo]
        let delegateInfos: [LifecycleIndexPass.DelegatePropertyInfo]
        let streamInfos: [LifecycleIndexPass.StreamCreationInfo]
    }

    private func auditDirectory(
        at path: String,
        config: MemoryLifecycleConfig
    ) -> AuditResult {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var taskInfos: [LifecycleIndexPass.TaskPropertyInfo] = []
        var delegateInfos: [LifecycleIndexPass.DelegatePropertyInfo] = []
        var streamInfos: [LifecycleIndexPass.StreamCreationInfo] = []
        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return AuditResult(diagnostics: [], taskInfos: [], delegateInfos: [], streamInfos: [])
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            guard !relativePath.contains("Tests/") else { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            let isExempt = config.exemptFiles.contains { exemptPattern in
                fullPath.contains(exemptPattern)
            }
            guard !isExempt else { continue }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let tree = Parser.parse(source: source)
                let visitor = LifecycleVisitor(
                    filePath: fullPath,
                    source: source,
                    config: config,
                    tree: tree
                )
                visitor.walk(tree)
                diagnostics.append(contentsOf: visitor.diagnostics)
                taskInfos.append(contentsOf: visitor.taskPropertyInfos)
                delegateInfos.append(contentsOf: visitor.delegatePropertyInfos)
                streamInfos.append(contentsOf: visitor.streamCreationInfos)
            } catch {
                continue
            }
        }
        return AuditResult(diagnostics: diagnostics, taskInfos: taskInfos, delegateInfos: delegateInfos, streamInfos: streamInfos)
    }
}
