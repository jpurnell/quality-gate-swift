import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source for non-deterministic randomness usage that lacks seed injection.
///
/// Scientific computing, simulations, and testing rely on reproducible results.
/// This auditor flags randomness APIs that cannot be controlled via a
/// `RandomNumberGenerator` parameter, making results non-reproducible.
///
/// Detected rules:
/// - `stochastic-no-seed` — `.random()`, `.random(in:)`, or
///   `SystemRandomNumberGenerator` used in a function without an RNG parameter
/// - `stochastic-global-state` — C-style global random functions
///   (`drand48`, `srand48`, `arc4random`, `arc4random_uniform`)
/// - `stochastic-collection-shuffle` — `.shuffled()` or `.shuffle()` without
///   a `using:` parameter
///
/// ## What runs in `Tests/`, and what does not
///
/// `Tests/` used to be skipped outright. It is now walked, but only for the rules nothing
/// else in the gate implements: `stochastic-global-state`, and `stochastic-collection-shuffle`
/// restricted to the in-place `.shuffle()` spelling.
///
/// `TestQualityAuditor`'s `unseeded-random` already covers `.random(…)`, `.shuffled(…)` and
/// `SystemRandomNumberGenerator` in test code at the same severity, so this auditor stays
/// quiet on those three. Two checkers warning on one line is how a rule becomes noise, and
/// `unseeded-random` gives the better advice for a test anyway — seed a generator locally.
/// The gap it leaves is the C-style global functions and the `shuffle`/`shuffled` spelling
/// split, which is exactly what this auditor now claims.
///
/// ## Configuration
///
/// Use `StochasticDeterminismConfig` to control behavior:
/// - `exemptFunctions` — function names exempt from the seed requirement
/// - `exemptFiles` — file paths to skip entirely
/// - `flagCollectionShuffle` — enable/disable the shuffle rule
/// - `flagGlobalState` — enable/disable the global state rule
/// - `auditTests` — whether `Tests/` is walked at all
///
/// ## Suppression
///
/// Add `// stochastic:exempt` on a source line to suppress all stochastic
/// diagnostics on that line.
public struct StochasticDeterminismAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "StochasticDeterminismAuditor")

    /// Unique identifier for this checker.
    public let id = "stochastic-determinism"
    /// Human-readable display name for this checker.
    public let name = "Stochastic Determinism Auditor"

    /// Creates a stochastic determinism auditor.
    public init() {}

    /// Audits all Swift files under the `Sources/` directory for
    /// non-deterministic randomness usage.
    ///
    /// - Parameter configuration: Project-specific configuration including
    ///   `stochasticDeterminism` settings.
    /// - Returns: A `CheckResult` with status `.warning` if diagnostics were
    ///   found, `.passed` otherwise.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")
        let testsPath = (currentDir as NSString).appendingPathComponent("Tests")
        let config = configuration.stochasticDeterminism

        var allDiagnostics: [Diagnostic] = []
        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project sources
            let result = auditDirectory(at: sourcesPath, config: config)
            allDiagnostics.append(contentsOf: result)
        }
        if config.auditTests, fileManager.fileExists(atPath: testsPath) { // SAFETY: CLI tool reads local project tests
            let result = auditDirectory(at: testsPath, config: config)
            allDiagnostics.append(contentsOf: result)
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

    /// Audits a single source string for stochastic determinism issues.
    ///
    /// Useful for testing or single-file analysis without filesystem access.
    ///
    /// - Parameters:
    ///   - source: The Swift source code to analyze.
    ///   - fileName: The file path used in emitted diagnostics.
    ///   - configuration: The quality-gate configuration.
    /// - Returns: A `CheckResult` with all diagnostics found.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let diags = auditSourceCode(
            source,
            fileName: fileName,
            config: configuration.stochasticDeterminism
        )
        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = diags.isEmpty ? .passed : .warning
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diags,
            duration: duration
        )
    }

    // MARK: - Private

    private func auditDirectory(
        at path: String,
        config: StochasticDeterminismConfig
    ) -> [Diagnostic] {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        guard let enumerator = fileManager.enumerator(atPath: path) else { return [] }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            // Skip exempt files
            if config.exemptFiles.contains(where: { relativePath.contains($0) }) {
                continue
            }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let diags = auditSourceCode(source, fileName: fullPath, config: config)
                diagnostics.append(contentsOf: diags)
            } catch {
                Self.logger.warning("Skipping unreadable source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
        return diagnostics
    }

    private func auditSourceCode(
        _ source: String,
        fileName: String,
        config: StochasticDeterminismConfig
    ) -> [Diagnostic] {
        let sourceLines = source.lines
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = StochasticVisitor(
            filePath: fileName,
            converter: converter,
            sourceLines: sourceLines,
            flagCollectionShuffle: config.flagCollectionShuffle,
            flagGlobalState: config.flagGlobalState,
            exemptFunctions: Set(config.exemptFunctions)
        )
        visitor.walk(tree)
        return visitor.diagnostics
    }
}
