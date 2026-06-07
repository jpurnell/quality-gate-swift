import Foundation
import os
import QualityGateCore
import SwiftSyntax
import SwiftParser
import IndexStoreInfra

/// Scans Swift source files for infinite-recursion bugs that compile cleanly.
///
/// See the design proposal at
/// `development-guidelines/02_IMPLEMENTATION_PLANS/UPCOMING/RECURSION_AUDITOR_design.md`
/// for the full rule list and rationale.
public struct RecursionAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "RecursionAuditor")

    /// Unique identifier for this checker.
    public let id = "recursion"
    /// Human-readable name shown in quality-gate output.
    public let name = "Recursion Auditor"

    /// Creates a new recursion auditor.
    public init() {}

    /// Scans all Swift files under `Sources/` for infinite-recursion patterns.
    /// - Parameter configuration: The quality-gate configuration for this run.
    /// - Returns: A check result containing any recursion diagnostics found.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var sources: [(fileName: String, source: String)] = []
        if fileManager.fileExists(atPath: sourcesPath), // SAFETY: CLI tool reads local project sources
           let enumerator = fileManager.enumerator(atPath: sourcesPath) {
            while let relativePath = enumerator.nextObject() as? String {
                guard relativePath.hasSuffix(".swift") else { continue }
                let fullPath = (sourcesPath as NSString).appendingPathComponent(relativePath)
                do {
                    let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                    sources.append((fullPath, source))
                } catch {
                    Self.logger.warning("Skipping unreadable source file: \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        let result = try await auditProject(sources: sources, configuration: configuration)
        let duration = ContinuousClock.now - startTime
        return CheckResult(
            checkerId: id,
            status: result.status,
            diagnostics: result.diagnostics,
            duration: duration
        )
    }

    /// Single-file audit. Cycle detection considers only the one file.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        try await auditProject(sources: [(fileName, source)], configuration: configuration)
    }

    /// Multi-file audit. Builds a project-wide call graph for cross-file
    /// mutual recursion detection. When an IndexStoreDB session is available
    /// and `configuration.recursion.useIndexStore` is true, Pass 2 (USR-based
    /// cycle detection) runs after the syntactic Pass 1, confirming or
    /// rejecting name-based mutual-cycle findings and detecting cross-module
    /// and protocol-witness cycles.
    public func auditProject(
        sources: [(fileName: String, source: String)],
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        // Pre-pass: collect protocol names across the entire project so the
        // protocol-extension-default rule has the context it needs.
        let protocolNames = collectProtocolNames(in: sources)

        var allDeclarations: [DeclarationInfo] = []
        var allDiagnostics: [Diagnostic] = []
        for entry in sources {
            let analysis = analyzeFile(
                source: entry.source,
                fileName: entry.fileName,
                protocolNames: protocolNames
            )
            allDeclarations.append(contentsOf: analysis.declarations)
            allDiagnostics.append(contentsOf: analysis.diagnostics)
        }

        // Pass 1: Project-wide mutual cycle detection (name-based, rule 8).
        let nameBasedCycleDiagnostics = detectMutualCyclesImpl(declarations: allDeclarations)

        // Pass 2: USR-based cycle detection via IndexStoreDB (when available).
        if configuration.recursion.useIndexStore {
            do {
                let pass2Diagnostics = try runIndexStorePass(configuration: configuration)
                allDiagnostics.append(contentsOf: pass2Diagnostics)

                for diag in nameBasedCycleDiagnostics {
                    allDiagnostics.append(RecursionIndexPass.demoteToNote(diag))
                }
            } catch {
                Self.logger.warning("IndexStore pass failed, falling back to name-based cycle detection: \(error.localizedDescription, privacy: .public)")
                allDiagnostics.append(contentsOf: nameBasedCycleDiagnostics)
                allDiagnostics.append(contentsOf: RecursionIndexPass.runWithoutIndex())
            }
        } else {
            allDiagnostics.append(contentsOf: nameBasedCycleDiagnostics)
        }

        let duration = ContinuousClock.now - startTime
        let hasErrors = allDiagnostics.contains { $0.severity == .error }
        let status: CheckResult.Status = hasErrors ? .failed : .passed
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            duration: duration
        )
    }

    // MARK: - Private

    private func collectProtocolNames(in sources: [(fileName: String, source: String)]) -> Set<String> {
        var names: Set<String> = []
        for entry in sources {
            let tree = Parser.parse(source: entry.source)
            let collector = ProtocolNameCollector(viewMode: .sourceAccurate)
            collector.walk(tree)
            names.formUnion(collector.protocolNames)
        }
        return names
    }

    private func analyzeFile(
        source: String,
        fileName: String,
        protocolNames: Set<String>
    ) -> FileAnalysis {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = RecursionVisitor(
            fileName: fileName,
            source: source,
            converter: converter,
            protocolNames: protocolNames
        )
        visitor.walk(tree)
        return FileAnalysis(
            diagnostics: visitor.diagnostics,
            declarations: visitor.declarations
        )
    }

    /// Runs the IndexStoreDB-backed Pass 2 for USR-based cycle detection.
    private func runIndexStorePass(configuration: Configuration) throws -> [Diagnostic] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let kind = ProjectKind.detect(at: cwd)

        guard let located = try StoreLocator.locate(projectKind: kind) else {
            throw IndexStorePassError.noIndexStore
        }

        guard let libPath = IndexStoreSession.findLibIndexStore() else {
            throw IndexStorePassError.toolchainNotFound
        }

        let session = try IndexStoreSession(storePath: located.url, libPath: libPath)
        let swiftFiles = SourceWalker.swiftFiles(under: kind.rootURL, excludePatterns: configuration.excludePatterns)

        return try RecursionIndexPass.run(
            session: session,
            swiftFiles: swiftFiles,
            baseCaseUSRs: []
        )
    }

    /// Errors specific to the IndexStore pass integration.
    enum IndexStorePassError: Error {
        /// No index store could be located for the project.
        case noIndexStore
        /// The Swift toolchain or libIndexStore.dylib could not be found.
        case toolchainNotFound
    }

    private func detectMutualCyclesImpl(declarations: [DeclarationInfo]) -> [Diagnostic] {
        // Build the callable subgraph: only functions/methods participate.
        let callable = declarations.filter { $0.isCallable }
        // Index declarations by signature for quick lookup.
        var signatureToIndex: [Signature: Int] = [:]
        for (index, decl) in callable.enumerated() {
            // First declaration wins on collision (overload sets are rare in test fixtures).
            if signatureToIndex[decl.signature] == nil {
                signatureToIndex[decl.signature] = index
            }
        }

        // Adjacency list keyed by index.
        var adjacency: [[Int]] = Array(repeating: [], count: callable.count)
        for (sourceIndex, decl) in callable.enumerated() {
            for call in decl.outgoingCalls {
                for candidate in call.candidateSignatures {
                    if let targetIndex = signatureToIndex[candidate] {
                        adjacency[sourceIndex].append(targetIndex)
                    }
                }
            }
        }

        // Tarjan's strongly connected components.
        let sccs = tarjanSCCs(adjacency: adjacency)

        var diagnostics: [Diagnostic] = []
        for component in sccs where component.count >= 2 {
            // If any participant has a base case the cycle can terminate.
            let hasBaseCase = component.contains { callable[$0].hasBaseCase }
            if hasBaseCase { continue }

            for memberIndex in component {
                let decl = callable[memberIndex]
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "function '\(decl.signature.displayName)' participates in a mutual recursion cycle with no base case",
                    filePath: decl.location.file,
                    lineNumber: decl.location.line,
                    columnNumber: decl.location.column,
                    ruleId: "recursion.mutual-cycle",
                    suggestedFix: "Add a guard-driven base case to one of the cycle participants."
                ))
            }
        }
        return diagnostics
    }

    private func tarjanSCCs(adjacency: [[Int]]) -> [[Int]] {
        let count = adjacency.count
        var index = 0
        var sccStack: [Int] = []
        var indices: [Int?] = Array(repeating: nil, count: count)
        var lowlinks: [Int] = Array(repeating: 0, count: count)
        var onStack: [Bool] = Array(repeating: false, count: count)
        var result: [[Int]] = []

        struct Frame {
            let node: Int
            var neighborIndex: Int
            let parent: Int?
        }

        for startNode in 0..<count where indices[startNode] == nil {
            var workStack = [Frame(node: startNode, neighborIndex: 0, parent: nil)]
            indices[startNode] = index
            lowlinks[startNode] = index
            index += 1
            sccStack.append(startNode)
            onStack[startNode] = true

            while let frame = workStack.last {
                let v = frame.node
                let neighbors = adjacency[v]

                if frame.neighborIndex < neighbors.count {
                    let w = neighbors[frame.neighborIndex]
                    workStack[workStack.count - 1].neighborIndex += 1

                    if indices[w] == nil {
                        indices[w] = index
                        lowlinks[w] = index
                        index += 1
                        sccStack.append(w)
                        onStack[w] = true
                        workStack.append(Frame(node: w, neighborIndex: 0, parent: v))
                    } else if onStack[w] {
                        if let wIdx = indices[w] {
                            lowlinks[v] = min(lowlinks[v], wIdx)
                        }
                    }
                } else {
                    if let vIdx = indices[v], lowlinks[v] == vIdx {
                        var component: [Int] = []
                        while true { // SAFETY: loop terminates when sccStack is empty or w == v
                            guard let w = sccStack.popLast() else { break }
                            onStack[w] = false
                            component.append(w)
                            if w == v { break }
                        }
                        result.append(component)
                    }

                    workStack.removeLast()
                    if let parent = frame.parent {
                        lowlinks[parent] = min(lowlinks[parent], lowlinks[v])
                    }
                }
            }
        }
        return result
    }
}

// MARK: - Supporting Types

/// A declaration found in a Swift source file.
struct DeclarationInfo {
    let signature: Signature
    let location: SourceLocation
    /// True if the body contains a guard-driven early exit.
    let hasBaseCase: Bool
    /// Outgoing call sites collected from the body.
    let outgoingCalls: [CallSite]
    /// True if this declaration participates in cycle detection (functions/methods).
    let isCallable: Bool
}

/// A signature uniquely identifying a callable within its enclosing type context.
struct Signature: Hashable {
    /// Lexical type context. Empty for free declarations, otherwise dot-joined
    /// type names like "Foo" or "Foo.Inner".
    let typeContext: String
    /// Display name with argument labels: `f(_:x:)`, `init(name:)`,
    /// `subscript(_:)`, or for properties just the property name.
    let displayName: String
}

/// A call site within a declaration body, with the candidate signatures it
/// might resolve to. The graph builder picks any candidate that exists as a
/// declaration in the project.
struct CallSite {
    let candidateSignatures: [Signature]
}

/// Source location for a diagnostic.
struct SourceLocation {
    let file: String
    let line: Int
    let column: Int
}

/// Per-file analysis result.
struct FileAnalysis {
    let diagnostics: [Diagnostic]
    let declarations: [DeclarationInfo]
}
