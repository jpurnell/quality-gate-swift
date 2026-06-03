import Foundation
import IndexStoreInfra
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Advisory-only checker that computes cognitive complexity per function.
///
/// This checker never fails a build. It reports functions above the configured
/// threshold as informational notes, and produces structured complexity data
/// for corpus integration.
public struct ComplexityAnalyzer: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "complexity"
    /// Human-readable name shown in quality-gate output.
    public let name = "Complexity Analyzer"

    /// Creates a new complexity analyzer.
    public init() {}

    /// Runs complexity analysis and returns advisory diagnostics for functions above threshold.
    ///
    /// Pass 1 scans all Swift source files syntactically. When both
    /// `configuration.complexity.useIndexStore` and
    /// `configuration.complexity.crossModuleAmplification` are enabled,
    /// Pass 2 resolves cross-module call edges via IndexStoreDB and computes
    /// amplified cognitive complexity scores. Any Pass 2 failure degrades
    /// gracefully — the checker emits an informational note and continues
    /// with Pass 1 results only.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let threshold = configuration.complexity.cognitiveThreshold
        var records = scanProject(configuration: configuration)

        var diagnostics: [Diagnostic] = []
        for record in records where record.cognitiveComplexity > threshold {
            let moduleThreshold = configuration.complexity.moduleThresholds[record.moduleName] ?? threshold
            guard record.cognitiveComplexity > moduleThreshold else { continue }

            var message = "\(record.functionName) has cognitive complexity \(record.cognitiveComplexity) (threshold: \(moduleThreshold))"
            if record.estimatedTimeComplexity != "O(1)" {
                message += ", estimated \(record.estimatedTimeComplexity)"
            }
            diagnostics.append(Diagnostic(
                severity: .note,
                message: message,
                filePath: record.filePath,
                lineNumber: record.startLine,
                ruleId: "complexity.cognitive-threshold"
            ))
        }

        for record in records {
            for pattern in record.detectedPatterns {
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: patternMessage(pattern, in: record.functionName),
                    filePath: record.filePath,
                    lineNumber: patternLine(pattern),
                    ruleId: patternRuleId(pattern)
                ))
            }

            for basis in record.complexityBasis {
                if case .callGraphAmplification(let callee, let calleeCost) = basis {
                    diagnostics.append(Diagnostic(
                        severity: .note,
                        message: "\(record.functionName) calls \(callee) (\(calleeCost)) inside a loop — effective \(record.estimatedTimeComplexity)",
                        filePath: record.filePath,
                        lineNumber: record.startLine,
                        ruleId: "complexity.call-graph-amplification"
                    ))
                }
            }
        }

        // Pass 2: Cross-module cognitive complexity amplification via IndexStoreDB.
        if configuration.complexity.useIndexStore && configuration.complexity.crossModuleAmplification {
            do {
                let edges = try resolveCrossModuleEdges(records: records, configuration: configuration)
                let inputs = ComplexityIndexPass.Inputs(
                    records: records,
                    edges: edges,
                    crossModuleMaxDepth: configuration.complexity.crossModuleMaxDepth,
                    cognitiveThreshold: threshold,
                    amplifiedCognitiveThreshold: configuration.complexity.amplifiedCognitiveThreshold,
                    moduleThresholds: configuration.complexity.moduleThresholds
                )
                let output = ComplexityIndexPass.run(inputs: inputs)
                records = output.records
                diagnostics.append(contentsOf: output.diagnostics)
            } catch { // logging: Pass 2 failure captured as note diagnostic; analysis continues with Pass 1 results
                diagnostics.append(ComplexityIndexPass.unavailableNote())
            }
        }

        let duration = ContinuousClock.now - startTime
        return CheckResult(
            checkerId: id,
            status: .passed,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    /// Scans all Swift source files under Sources/ and returns per-function complexity records.
    public func scanProject(configuration: Configuration) -> [FunctionComplexityRecord] {
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allRecords: [FunctionComplexityRecord] = []
        let callGraphEnabled = configuration.complexity.callGraphEnabled
        let maxDepth = configuration.complexity.callGraphMaxDepth
        let userCosts = Self.buildUserCostDictionary(from: configuration.complexity.knownCosts)

        guard fileManager.fileExists(atPath: sourcesPath), // SAFETY: CLI tool reads local project sources
              let enumerator = fileManager.enumerator(atPath: sourcesPath) else {
            return []
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let fullPath = (sourcesPath as NSString).appendingPathComponent(relativePath)
            guard let source = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue } // silent: unreadable file skipped

            let moduleName = extractModuleName(from: relativePath)

            if callGraphEnabled {
                let records = CallGraphAmplifier.analyze(
                    source: source,
                    moduleName: moduleName,
                    maxDepth: maxDepth,
                    userCosts: userCosts
                )
                let withPaths = records.map { record in
                    FunctionComplexityRecord(
                        functionName: record.functionName,
                        moduleName: record.moduleName,
                        filePath: fullPath,
                        startLine: record.startLine,
                        endLine: record.endLine,
                        cognitiveComplexity: record.cognitiveComplexity,
                        cognitiveBreakdown: record.cognitiveBreakdown,
                        estimatedTimeComplexity: record.estimatedTimeComplexity,
                        complexityBasis: record.complexityBasis,
                        confidence: record.confidence,
                        detectedPatterns: record.detectedPatterns
                    )
                }
                allRecords.append(contentsOf: withPaths)
            } else {
                let records = CognitiveComplexityVisitor.analyze(
                    source: source,
                    filePath: fullPath,
                    moduleName: moduleName,
                    userCosts: userCosts
                )
                allRecords.append(contentsOf: records)
            }
        }

        return allRecords
    }

    /// Analyzes a single source string and returns per-function complexity records.
    public func analyzeSource(
        _ source: String,
        filePath: String = "<test>",
        moduleName: String = "Test",
        callGraphEnabled: Bool = false,
        callGraphMaxDepth: Int = 1,
        userCosts: [String: String] = [:]
    ) -> [FunctionComplexityRecord] {
        guard callGraphEnabled else {
            return CognitiveComplexityVisitor.analyze(
                source: source,
                filePath: filePath,
                moduleName: moduleName,
                userCosts: userCosts
            )
        }
        return CallGraphAmplifier.analyze(
            source: source,
            moduleName: moduleName,
            maxDepth: callGraphMaxDepth,
            userCosts: userCosts
        )
    }

    /// Builds a dictionary from KnownCostEntry array for efficient lookup.
    static func buildUserCostDictionary(from entries: [QualityGateCore.KnownCostEntry]) -> [String: String] {
        var dict: [String: String] = [:]
        for entry in entries {
            dict[entry.pattern] = entry.cost
        }
        return dict
    }

    private func extractModuleName(from relativePath: String) -> String {
        let components = relativePath.split(separator: "/")
        guard let first = components.first else { return "Unknown" }
        return String(first)
    }

    private func patternMessage(_ pattern: ComplexityPattern, in functionName: String) -> String {
        switch pattern {
        case .containsInFilter(let collection, _):
            return "\(functionName): linear search on '\(collection)' inside iteration — consider using a Set"
        case .nestedLoopSameCollection(let collection, _, _):
            return "\(functionName): nested loop over '\(collection)' — O(n²)"
        case .repeatedLinearSearch(let collection, let count):
            return "\(functionName): \(count) linear searches on '\(collection)' — consider a Dictionary"
        case .sortInLoop(_):
            return "\(functionName): sort inside loop — consider hoisting outside"
        case .quadraticStringConcat(_):
            return "\(functionName): string += in loop — consider joined() or array accumulation"
        }
    }

    private func patternLine(_ pattern: ComplexityPattern) -> Int {
        switch pattern {
        case .containsInFilter(_, let line): return line
        case .nestedLoopSameCollection(_, _, let innerLine): return innerLine
        case .repeatedLinearSearch(_, _): return 0
        case .sortInLoop(let line): return line
        case .quadraticStringConcat(let line): return line
        }
    }

    private func patternRuleId(_ pattern: ComplexityPattern) -> String {
        switch pattern {
        case .containsInFilter: return "complexity.contains-in-filter"
        case .nestedLoopSameCollection: return "complexity.nested-loop-same-collection"
        case .repeatedLinearSearch: return "complexity.repeated-linear-search"
        case .sortInLoop: return "complexity.sort-in-loop"
        case .quadraticStringConcat: return "complexity.quadratic-string-concat"
        }
    }

    // MARK: - Pass 2 Index Store Integration

    /// Errors specific to the index store pass integration.
    private enum IndexStorePassError: Error {
        /// No index store could be located for the project.
        case noIndexStore
        /// The Swift toolchain or libIndexStore.dylib could not be found.
        case toolchainNotFound
    }

    /// Resolves cross-module call edges from the index store for all Pass 1 records.
    ///
    /// Opens an IndexStoreDB session, enumerates all callable symbols across
    /// the project's source files, and identifies function calls that cross
    /// module boundaries. Each cross-module call is returned as a
    /// ``CrossModuleCallEdge`` suitable for ``ComplexityIndexPass``.
    ///
    /// - Parameters:
    ///   - records: Pass 1 function complexity records.
    ///   - configuration: The quality-gate configuration for this run.
    /// - Returns: An array of cross-module call edges.
    /// - Throws: ``IndexStorePassError`` when the index store or toolchain is unavailable.
    private func resolveCrossModuleEdges(
        records: [FunctionComplexityRecord],
        configuration: Configuration
    ) throws -> [CrossModuleCallEdge] {
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

        // Build a complexity lookup keyed by "moduleName.functionName" from Pass 1 records.
        var complexityByKey: [String: Int] = [:]
        for record in records {
            let key = "\(record.moduleName).\(record.functionName)"
            complexityByKey[key] = record.cognitiveComplexity
        }

        // Build a lookup of (symbol name -> [(usr, moduleName, filePath)]) for all callable
        // symbols in the project. Module membership is derived from the symbol's definition
        // location within the Sources/ directory hierarchy.
        let allSymbols = ConformanceQuery.symbolsInFiles(swiftFiles, in: session)
        var symbolsByName: [String: [(usr: String, moduleName: String, filePath: String)]] = [:]
        for (symbol, filePath) in allSymbols {
            guard isCallableSymbol(symbol) else { continue }
            let moduleName = moduleNameFromFilePath(filePath)
            symbolsByName[symbol.name, default: []].append((
                usr: symbol.usr,
                moduleName: moduleName,
                filePath: filePath
            ))
        }

        // For each record, find call edges that cross module boundaries by
        // querying the index for references (calls) to symbols in other modules.
        var edges: [CrossModuleCallEdge] = []
        for record in records {
            let callerModule = record.moduleName
            let callerKey = "\(callerModule).\(record.functionName)"

            // Find the caller's USR by looking up symbols matching the function name
            // in the caller's module.
            let callerCandidates = symbolsByName[record.functionName] ?? []
            let callerInfo = callerCandidates.first { $0.moduleName == callerModule }
            guard let callerUSR = callerInfo?.usr else { continue }

            // Query all call sites from this function via the index.
            let refs = ConformanceQuery.findReferences(
                toUSR: callerUSR,
                in: session,
                roles: .containedBy
            )
            // Not used directly — instead, look at what this function calls by
            // finding all symbols it references with a .call role.
            _ = refs

            // Approach: for each callable symbol in other modules, check if the
            // caller references it. This is more reliable than trying to find
            // outgoing calls from the caller's USR.
            for (calleeName, calleeEntries) in symbolsByName {
                for calleeEntry in calleeEntries {
                    guard calleeEntry.moduleName != callerModule else { continue }

                    // Check if this callee is called from within the caller's file.
                    let callRefs = ConformanceQuery.findReferences(
                        toUSR: calleeEntry.usr,
                        in: session,
                        roles: .call
                    )
                    for ref in callRefs {
                        let refModule = moduleNameFromFilePath(ref.filePath)
                        guard refModule == callerModule else { continue }

                        // Determine whether the call is inside a loop by checking
                        // the record's complexity basis for call-graph amplification.
                        let insideLoop = record.complexityBasis.contains { basis in
                            if case .callGraphAmplification(let callee, _) = basis {
                                return callee == calleeName
                            }
                            return false
                        }

                        let calleeCost = complexityByKey["\(calleeEntry.moduleName).\(calleeName)"] ?? 0

                        edges.append(CrossModuleCallEdge(
                            callerUSR: callerKey,
                            calleeUSR: "\(calleeEntry.moduleName).\(calleeName)",
                            calleeName: calleeName,
                            calleeModule: calleeEntry.moduleName,
                            calleeCognitiveComplexity: calleeCost,
                            insideLoop: insideLoop,
                            line: ref.line
                        ))
                    }
                }
            }
        }

        return edges
    }

    /// Determines the module name from an absolute file path by extracting the
    /// first directory component after `Sources/`.
    ///
    /// Falls back to `"Unknown"` when the path does not contain a `Sources/`
    /// directory segment.
    ///
    /// - Parameter filePath: Absolute path to a Swift source file.
    /// - Returns: The inferred module name.
    private func moduleNameFromFilePath(_ filePath: String) -> String {
        guard let sourcesRange = filePath.range(of: "/Sources/") else { return "Unknown" }
        let afterSources = filePath[sourcesRange.upperBound...]
        let components = afterSources.split(separator: "/")
        guard let first = components.first else { return "Unknown" }
        return String(first)
    }

    /// Returns whether an IndexStoreDB symbol represents a callable declaration.
    ///
    /// Matches functions, instance methods, static methods, and class methods.
    ///
    /// - Parameter symbol: The symbol to check.
    /// - Returns: `true` if the symbol is callable.
    private func isCallableSymbol(_ symbol: Symbol) -> Bool {
        switch symbol.kind {
        case .function, .instanceMethod, .staticMethod, .classMethod:
            return true
        default:
            return false
        }
    }
}
