import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source files for infinite-recursion bugs that compile cleanly.
///
/// See the design proposal at
/// `development-guidelines/02_IMPLEMENTATION_PLANS/UPCOMING/RECURSION_AUDITOR_design.md`
/// for the full rule list and rationale.
public struct RecursionAuditor: QualityChecker, Sendable {
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
                if let source = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                    sources.append((fullPath, source))
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
    /// mutual recursion detection.
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

        // Project-wide mutual cycle detection (rule 8).
        allDiagnostics.append(contentsOf: detectMutualCycles(declarations: allDeclarations))

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .failed
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
            converter: converter,
            protocolNames: protocolNames
        )
        visitor.walk(tree)
        return FileAnalysis(
            diagnostics: visitor.diagnostics,
            declarations: visitor.declarations
        )
    }

    private func detectMutualCycles(declarations: [DeclarationInfo]) -> [Diagnostic] {
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
        var index = 0
        var stack: [Int] = []
        var indices: [Int?] = Array(repeating: nil, count: adjacency.count)
        var lowlinks: [Int] = Array(repeating: 0, count: adjacency.count)
        var onStack: [Bool] = Array(repeating: false, count: adjacency.count)
        var result: [[Int]] = []

        func strongConnect(_ v: Int) {
            indices[v] = index
            lowlinks[v] = index
            index += 1
            stack.append(v)
            onStack[v] = true

            for w in adjacency[v] {
                if indices[w] == nil {
                    strongConnect(w)
                    lowlinks[v] = min(lowlinks[v], lowlinks[w])
                } else if onStack[w] {
                    if let wIdx = indices[w] {
                        lowlinks[v] = min(lowlinks[v], wIdx)
                    }
                }
            }

            if let vIdx = indices[v], lowlinks[v] == vIdx {
                var component: [Int] = []
                while true { // SAFETY: loop always terminates — breaks when stack is empty or when w == v
                    guard let w = stack.popLast() else { break }
                    onStack[w] = false
                    component.append(w)
                    if w == v { break }
                }
                result.append(component)
            }
        }

        for v in 0..<adjacency.count where indices[v] == nil {
            strongConnect(v)
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
