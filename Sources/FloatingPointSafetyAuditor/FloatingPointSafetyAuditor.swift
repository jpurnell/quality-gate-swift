import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source for floating-point safety issues.
///
/// Detected rules:
/// - `fp-equality` — exact `==` / `!=` comparison on floating-point operands
/// - `fp-division-unguarded` — division by a floating-point value without a
///   visible zero guard in the enclosing scope
///
/// Both rules emit warnings (not errors) because heuristic detection from
/// syntax alone cannot guarantee the operand types. False positives are
/// preferable to silent precision bugs.
///
/// ## Configuration
///
/// Use `FloatingPointSafetyAuditorConfig` to control behavior:
/// - `allowedFiles` — file paths to skip entirely
/// - `checkDivisionGuards` — enable/disable the `fp-division-unguarded` rule
///
/// ## Suppression
///
/// Add `// fp-safety:disable` on a source line to suppress all FP diagnostics
/// on that line.
public struct FloatingPointSafetyAuditor: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "fp-safety"
    /// Human-readable display name for this checker.
    public let name = "Floating-Point Safety Auditor"

    /// Creates a floating-point safety auditor.
    public init() {}

    /// Audits all Swift files under the `Sources/` directory for floating-point
    /// safety violations.
    ///
    /// - Parameter configuration: Project-specific configuration including
    ///   `fpSafety` settings.
    /// - Returns: A `CheckResult` with status `.warning` if diagnostics were
    ///   found, `.passed` otherwise.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []
        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project sources
            let result = auditDirectory(
                at: sourcesPath,
                config: configuration.fpSafety
            )
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

    /// Audits a single source string for floating-point safety issues.
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
            config: configuration.fpSafety
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
        config: FloatingPointSafetyAuditorConfig
    ) -> [Diagnostic] {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        guard let enumerator = fileManager.enumerator(atPath: path) else { return [] }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            // Skip allowed files
            if config.allowedFiles.contains(where: { relativePath.contains($0) }) {
                continue
            }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let diags = auditSourceCode(source, fileName: fullPath, config: config)
                diagnostics.append(contentsOf: diags)
            } catch {
                continue
            }
        }
        return diagnostics
    }

    private func auditSourceCode(
        _ source: String,
        fileName: String,
        config: FloatingPointSafetyAuditorConfig
    ) -> [Diagnostic] {
        // Whole-file disable: if the source contains a file-level disable comment
        // on a line by itself (not inline with code), skip it entirely.
        let sourceLines = source.components(separatedBy: "\n")
        for line in sourceLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "// fp-safety:disable" {
                return []
            }
        }

        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = FloatingPointSafetyVisitor(
            filePath: fileName,
            converter: converter,
            sourceLines: sourceLines,
            checkDivisionGuards: config.checkDivisionGuards
        )
        visitor.walk(tree)
        return visitor.diagnostics
    }
}
