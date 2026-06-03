import Foundation
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
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let threshold = configuration.complexity.cognitiveThreshold
        let records = scanProject(configuration: configuration)

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
}
