import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
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
    private static let logger = Logger(subsystem: "com.quality-gate", category: "MemoryLifecycleGuard")
    /// Unique identifier for this checker.
    public let id = "memory-lifecycle"
    /// Human-readable display name for this checker.
    public let name = "Memory Lifecycle Guard"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Stored Tasks without cancellation, strong delegate references, cross-file lifecycle analysis"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.correctness

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Creates a new memory lifecycle guard.
    public init() {}

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
        let root = configuration.resolvedProjectRoot
        // Hardcoded `Sources/` before this, so a retain cycle or an unbounded stream in
        // `Plugins/`, `Tests/`, or at the package root was never examined. `SourceWalker`
        // brings the configured exclusions the private enumerator ignored, too.
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)
        let config = configuration.memoryLifecycle

        var allDiagnostics: [Diagnostic] = []
        var allTaskInfos: [LifecycleIndexPass.TaskPropertyInfo] = []
        var allDelegateInfos: [LifecycleIndexPass.DelegatePropertyInfo] = []
        var allStreamInfos: [LifecycleIndexPass.StreamCreationInfo] = []

        let result = auditFiles(scan.files, config: config)
        allDiagnostics = result.diagnostics
        allTaskInfos = result.taskInfos
        allDelegateInfos = result.delegateInfos
        allStreamInfos = result.streamInfos

        if config.useIndexStore && !allDiagnostics.isEmpty {
            do {
                let pass2Diagnostics = try await runIndexPass(
                    root: configuration.resolvedProjectRoot,
                    pass1Diagnostics: allDiagnostics,
                    taskProperties: allTaskInfos,
                    delegateProperties: allDelegateInfos,
                    streamCreationSites: allStreamInfos
                )
                allDiagnostics = pass2Diagnostics
            } catch {
                Self.logger.warning("Memory Lifecycle Pass 2 skipped: \(error.localizedDescription, privacy: .public)")
                allDiagnostics.append(Diagnostic(
                    severity: .note,
                    message: "Memory Lifecycle Pass 2 skipped: \(error.localizedDescription)",
                    ruleId: "lifecycle.index-pass.skipped"
                ))
            }
        }

        // Appended *after* pass 2, which replaces `allDiagnostics` wholesale — a note added
        // before it would be silently discarded — and after the `!allDiagnostics.isEmpty`
        // gate above, which decides whether pass 2 runs at all. A coverage note added earlier
        // would make that condition true on every run and turn an optional pass into a
        // mandatory one.
        let plural = scan.files.count == 1 ? "" : "s"
        allDiagnostics.append(Diagnostic(
            severity: .note,
            message: "memory-lifecycle examined \(scan.files.count) file\(plural)"
                + (scan.exclusionClause.map { " · \($0)" } ?? ""),
            ruleId: "memory-lifecycle.coverage"))

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
        root: URL,
        pass1Diagnostics: [Diagnostic],
        taskProperties: [LifecycleIndexPass.TaskPropertyInfo],
        delegateProperties: [LifecycleIndexPass.DelegatePropertyInfo],
        streamCreationSites: [LifecycleIndexPass.StreamCreationInfo]
    ) async throws -> [Diagnostic] {
        let kind = ProjectKind.detect(at: root)

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
        let sourceFiles = SourceWalker.swiftFiles(under: root)
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

    /// Audits an already-scoped list of Swift files; the walk decides what the run owns.
    ///
    /// The `Tests/` skip below is kept, and it is a different thing from the hardcoded
    /// `Sources/` that used to bound this walk. That was an accident of where the enumerator
    /// was pointed; this is a stated judgement — a retain cycle in a test process that exits
    /// after the suite is not the defect this checker exists to find, and the pass-2 index
    /// work it would trigger is not free. It survives the widening deliberately.
    private func auditFiles(
        _ paths: [String],
        config: MemoryLifecycleConfig
    ) -> AuditResult {
        var diagnostics: [Diagnostic] = []
        var taskInfos: [LifecycleIndexPass.TaskPropertyInfo] = []
        var delegateInfos: [LifecycleIndexPass.DelegatePropertyInfo] = []
        var streamInfos: [LifecycleIndexPass.StreamCreationInfo] = []

        for fullPath in paths {
            guard !fullPath.contains("Tests/") else { continue }

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
                Self.logger.warning("Failed to read source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
        return AuditResult(diagnostics: diagnostics, taskInfos: taskInfos, delegateInfos: delegateInfos, streamInfos: streamInfos)
    }
}
