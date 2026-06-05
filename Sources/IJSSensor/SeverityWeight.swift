import Foundation

/// Severity-based weights for computing a weighted quality score across checkers.
///
/// Safety-critical checkers (concurrency, pointer-escape) carry full weight,
/// while informational checkers (consistency, status) carry minimal weight.
/// This ensures a single safety failure drops the score more than a
/// documentation lint miss.
public enum SeverityWeight: Sendable {
    /// Default checker-ID-to-weight mapping for all known checkers.
    public static let defaultWeightTable: [String: Double] = [
        "safety": 1.0,
        "concurrency": 1.0,
        "pointer-escape": 1.0,
        "recursion": 0.9,
        "test-quality": 0.8,
        "test": 0.8,
        "build": 0.8,
        "xcode-build": 0.8,
        "fp-safety": 0.8,
        "logging": 0.5,
        "process-safety": 0.5,
        "dependency-audit": 0.5,
        "stochastic-determinism": 0.5,
        "unreachable": 0.3,
        "swift-version": 0.3,
        "hig-auditor": 0.3,
        "complexity": 0.3,
        "context": 0.3,
        "accessibility": 0.3,
        "release-readiness": 0.3,
        "mcp-readiness": 0.3,
        "appintents-readiness": 0.3,
        "doc-coverage": 0.2,
        "doc-lint": 0.2,
        "status": 0.1,
        "consistency": 0.1,
        "memory-builder": 0.1,
        "memory-lifecycle": 0.1,
        "disk-clean": 0.1,
    ]

    /// Weight applied to checkers not found in the default table.
    public static let defaultUnknownWeight: Double = 0.3

    /// Computes a weighted quality score from checker pass/fail results.
    ///
    /// Score = 1.0 − (sum of failing weights) / (sum of all weights).
    /// Returns 1.0 when no checkers are provided.
    public static func weightedScore(
        checkerResults: [(checkerID: String, passed: Bool)]
    ) -> Double {
        guard !checkerResults.isEmpty else { return 1.0 }

        var totalWeight = 0.0
        var failWeight = 0.0

        for result in checkerResults {
            let weight = defaultWeightTable[result.checkerID] ?? defaultUnknownWeight
            totalWeight += weight
            if !result.passed {
                failWeight += weight
            }
        }

        guard totalWeight > 0 else { return 1.0 }
        return 1.0 - failWeight / totalWeight
    }
}
