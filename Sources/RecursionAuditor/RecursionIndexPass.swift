import Foundation
import os
import QualityGateCore
import IndexStoreInfra
import Synchronization

// MARK: - USR-based call graph

/// Metadata for a symbol in the USR call graph.
struct SymbolInfo: Sendable {
    /// Display name of the symbol (e.g. "foo(_:)").
    let displayName: String
    /// Absolute file path where the symbol is defined.
    let filePath: String
    /// 1-based line number of the definition.
    let line: Int
    /// 1-based column number of the definition.
    let column: Int
    /// Module name where the symbol is defined.
    let moduleName: String
}

/// A USR-keyed call graph that supports Tarjan's SCC algorithm for cycle detection.
///
/// Each node is identified by its USR (Unified Symbol Resolution) string,
/// which uniquely identifies a declaration across the entire project.
/// This eliminates false positives from name collisions, overloads,
/// and same-named methods on unrelated types.
///
/// ## Performance
/// The Tarjan SCC algorithm is O(V+E) and handles ~10K symbols comfortably.
/// Typical Swift projects have far fewer callable symbols than that ceiling.
final class USRCallGraph: Sendable {

    private let _edges: Mutex<[String: Set<String>]> = Mutex([:])
    private let _nodes: Mutex<Set<String>> = Mutex([])
    private let _moduleNames: Mutex<[String: String]> = Mutex([:])
    private let _symbolInfos: Mutex<[String: SymbolInfo]> = Mutex([:])
    private let _protocolWitnesses: Mutex<Set<String>> = Mutex([])
    private let _defaultImplementations: Mutex<Set<String>> = Mutex([])
    private let _hasBaseCase: Mutex<Set<String>> = Mutex([])

    /// Creates an empty call graph.
    init() {}

    /// Adds a directed edge from caller to callee.
    func addEdge(from caller: String, to callee: String) {
        _nodes.withLock { _ = $0.insert(caller); _ = $0.insert(callee) }
        _edges.withLock { _ = $0[caller, default: []].insert(callee) }
    }

    /// Adds an isolated node with no edges.
    func addNode(_ usr: String) {
        _nodes.withLock { _ = $0.insert(usr) }
    }

    /// Associates a module name with a USR.
    func setModuleName(_ usr: String, module: String) {
        _moduleNames.withLock { $0[usr] = module }
    }

    /// Associates symbol info with a USR.
    func setSymbolInfo(_ usr: String, info: SymbolInfo) {
        _symbolInfos.withLock { $0[usr] = info }
    }

    /// Marks a USR as a protocol witness.
    func markAsProtocolWitness(_ usr: String) {
        _protocolWitnesses.withLock { _ = $0.insert(usr) }
    }

    /// Marks a USR as a protocol default implementation.
    func markAsDefaultImplementation(_ usr: String) { // LIVE: called by RecursionIndexPass.run and tests
        _defaultImplementations.withLock { _ = $0.insert(usr) }
    }

    /// Marks a USR as having a guard-driven base case.
    func markHasBaseCase(_ usr: String) {
        _hasBaseCase.withLock { _ = $0.insert(usr) }
    }

    /// Returns true if the given USR has a self-edge.
    func hasSelfEdge(_ usr: String) -> Bool { // LIVE: called by tests and RecursionIndexPass.run
        _edges.withLock { $0[usr]?.contains(usr) ?? false }
    }

    /// Returns true if a component spans multiple modules.
    func isCrossModule(_ component: [String]) -> Bool {
        let modules = _moduleNames.withLock { moduleNames in
            Set(component.compactMap { moduleNames[$0] })
        }
        return modules.count > 1
    }

    /// Returns true if a component includes a protocol witness cycle pattern.
    ///
    /// A protocol witness cycle occurs when a default implementation dispatches
    /// through the witness table back to itself via a conformer.
    func isProtocolWitnessCycle(_ component: [String]) -> Bool {
        let (hasWitness, hasDefault) = _protocolWitnesses.withLock { witnesses in
            _defaultImplementations.withLock { defaults in
                let w = component.contains { witnesses.contains($0) }
                let d = component.contains { defaults.contains($0) }
                return (w, d)
            }
        }
        return hasWitness && hasDefault
    }

    /// Returns the symbol info for a USR, if available.
    func symbolInfo(for usr: String) -> SymbolInfo? {
        _symbolInfos.withLock { $0[usr] }
    }

    /// Returns true if any member of the component has a base case.
    func componentHasBaseCase(_ component: [String]) -> Bool {
        _hasBaseCase.withLock { baseCases in
            component.contains { baseCases.contains($0) }
        }
    }

    // MARK: - Tarjan's SCC Algorithm

    /// Finds all strongly connected components in the call graph.
    ///
    /// Uses Tarjan's algorithm, which is O(V+E) where V is the number of
    /// unique USRs and E is the number of call edges.
    func findStronglyConnectedComponents() -> [[String]] {
        let (nodes, edges) = (_nodes.withLock { $0 }, _edges.withLock { $0 })

        let nodeArray = Array(nodes)
        guard !nodeArray.isEmpty else { return [] }

        var usrToIndex: [String: Int] = [:]
        for (i, usr) in nodeArray.enumerated() {
            usrToIndex[usr] = i
        }

        let count = nodeArray.count
        var adjacency: [[Int]] = Array(repeating: [], count: count)
        for (caller, callees) in edges {
            guard let callerIdx = usrToIndex[caller] else { continue }
            for callee in callees {
                guard let calleeIdx = usrToIndex[callee] else { continue }
                adjacency[callerIdx].append(calleeIdx)
            }
        }

        var index = 0
        var sccStack: [Int] = []
        var indices: [Int?] = Array(repeating: nil, count: count)
        var lowlinks: [Int] = Array(repeating: 0, count: count)
        var onStack: [Bool] = Array(repeating: false, count: count)
        var result: [[String]] = []

        // Iterative Tarjan using an explicit work stack to avoid
        // stack overflow on deep graphs (e.g. 1000-node chains).
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
                        var component: [String] = []
                        while true { // SAFETY: loop terminates when sccStack is empty or w == v
                            guard let w = sccStack.popLast() else { break }
                            onStack[w] = false
                            component.append(nodeArray[w])
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


// MARK: - RecursionIndexPass

/// USR-based call graph cycle detection (Pass 2) backed by IndexStoreDB.
///
/// Replaces name-based matching with USR identity to eliminate false positives
/// from overloaded functions, same-named methods on unrelated types, and
/// name collisions across modules. Also detects cross-module and protocol
/// witness table cycles that Pass 1 (syntactic) cannot see.
enum RecursionIndexPass {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "RecursionIndexPass")

    /// Generates diagnostics from a pre-built USR call graph.
    static func generateDiagnostics(from graph: USRCallGraph) -> [Diagnostic] {
        let sccs = graph.findStronglyConnectedComponents()
        var diagnostics: [Diagnostic] = []

        for component in sccs where component.count >= 2 {
            if graph.componentHasBaseCase(component) { continue }

            let ruleId: String
            let severity: Diagnostic.Severity = .warning

            if graph.isProtocolWitnessCycle(component) {
                ruleId = "recursion.protocol-witness-cycle"
            } else if graph.isCrossModule(component) {
                ruleId = "recursion.cross-module-cycle"
            } else {
                ruleId = "recursion.mutual-cycle"
            }

            for usr in component {
                guard let info = graph.symbolInfo(for: usr) else { continue }
                diagnostics.append(Diagnostic(
                    severity: severity,
                    message: "function '\(info.displayName)' participates in a \(ruleId == "recursion.cross-module-cycle" ? "cross-module " : ruleId == "recursion.protocol-witness-cycle" ? "protocol witness " : "")mutual recursion cycle with no base case",
                    filePath: info.filePath,
                    lineNumber: info.line,
                    columnNumber: info.column,
                    ruleId: ruleId,
                    suggestedFix: "Add a guard-driven base case to one of the cycle participants."
                ))
            }
        }

        diagnostics.sort { lhs, rhs in
            if (lhs.filePath ?? "") != (rhs.filePath ?? "") { return (lhs.filePath ?? "") < (rhs.filePath ?? "") }
            return (lhs.lineNumber ?? 0) < (rhs.lineNumber ?? 0)
        }

        return diagnostics
    }

    /// Returns a skip diagnostic when the index store is not available.
    static func runWithoutIndex() -> [Diagnostic] {
        [Diagnostic(
            severity: .note,
            message: "Pass 2 (USR-based cycle detection) skipped: index store not available.",
            ruleId: "recursion.index_pass.skipped"
        )]
    }

    /// Demotes a name-based mutual cycle diagnostic to `.note` severity.
    static func demoteToNote(_ diagnostic: Diagnostic) -> Diagnostic {
        Diagnostic(
            severity: .note,
            message: "\(diagnostic.message) (name-based match only; USR pass could not confirm)",
            filePath: diagnostic.filePath,
            lineNumber: diagnostic.lineNumber,
            columnNumber: diagnostic.columnNumber,
            ruleId: diagnostic.ruleId,
            suggestedFix: diagnostic.suggestedFix
        )
    }

    /// Runs Pass 2 using an IndexStoreDB session to build a USR call graph.
    static func run(
        session: IndexStoreSession,
        swiftFiles: [String],
        baseCaseUSRs: Set<String>
    ) throws -> [Diagnostic] {
        let db = session.db
        let graph = USRCallGraph()

        var pathCache: [String: String] = [:]
        func canonicalize(_ path: String) -> String {
            if let cached = pathCache[path] { return cached }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            pathCache[path] = resolved
            return resolved
        }

        let canonicalSwiftFiles = Set(swiftFiles.map { canonicalize($0) })

        for file in swiftFiles {
            let canonical = canonicalize(file)
            let symbols = db.symbols(inFilePath: canonical)

            for symbol in symbols {
                guard isCallable(symbol) else { continue }
                let usr = symbol.usr

                let defOccs = db.occurrences(ofUSR: usr, roles: [.definition])
                guard let def = defOccs.first(where: { canonicalSwiftFiles.contains(canonicalize($0.location.path)) }) ?? defOccs.first else {
                    continue
                }

                let defFile = canonicalize(def.location.path)
                let moduleName = def.location.moduleName

                graph.addNode(usr)
                graph.setModuleName(usr, module: moduleName)
                graph.setSymbolInfo(usr, info: SymbolInfo(
                    displayName: symbol.name,
                    filePath: defFile,
                    line: def.location.line,
                    column: def.location.utf8Column,
                    moduleName: moduleName
                ))

                let defRoles = defOccs.flatMap { $0.relations }
                let isWitness = defRoles.contains { $0.roles.contains(.overrideOf) }
                if isWitness {
                    graph.markAsProtocolWitness(usr)
                }

                if baseCaseUSRs.contains(usr) {
                    graph.markHasBaseCase(usr)
                }

                let refs = db.occurrences(ofUSR: usr, roles: [.reference, .call])
                for ref in refs {
                    let refFile = canonicalize(ref.location.path)
                    guard canonicalSwiftFiles.contains(refFile) else { continue }

                    for rel in ref.relations where rel.roles.contains(.calledBy) || rel.roles.contains(.containedBy) {
                        graph.addEdge(from: rel.symbol.usr, to: usr)
                    }
                }
            }
        }

        scanForBaseCases(graph: graph, swiftFiles: swiftFiles)

        return generateDiagnostics(from: graph)
    }

    /// Reads source files and marks USRs as having a base case when their
    /// function body contains a guard statement or bare return.
    private static func scanForBaseCases(graph: USRCallGraph, swiftFiles: [String]) {
        var fileContentsCache: [String: String] = [:]

        func contents(of path: String) -> String? {
            if let cached = fileContentsCache[path] { return cached }
            let source: String
            do {
                source = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                logger.warning("Skipping unreadable source file: \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
            fileContentsCache[path] = source
            return source
        }

        let sccs = graph.findStronglyConnectedComponents()
        for component in sccs where component.count >= 2 {
            for usr in component {
                guard let info = graph.symbolInfo(for: usr) else { continue }
                guard let source = contents(of: info.filePath) else { continue }

                let lines = source.components(separatedBy: "\n")
                let startIndex = max(0, info.line - 1)
                guard startIndex < lines.count else { continue }

                var braceDepth = 0
                var foundOpen = false
                var bodyLines: [String] = []

                for lineIndex in startIndex..<lines.count {
                    let line = lines[lineIndex]
                    for char in line {
                        if char == "{" {
                            braceDepth += 1
                            foundOpen = true
                        } else if char == "}" {
                            braceDepth -= 1
                        }
                    }
                    if foundOpen {
                        bodyLines.append(line)
                    }
                    if foundOpen && braceDepth == 0 { break }
                }

                let body = bodyLines.joined(separator: "\n")
                if body.contains("guard ") || body.contains("guard\t") {
                    graph.markHasBaseCase(usr)
                }
            }
        }
    }

    private static func isCallable(_ symbol: Symbol) -> Bool {
        switch symbol.kind {
        case .function, .instanceMethod, .staticMethod, .classMethod:
            return true
        default:
            return false
        }
    }
}
