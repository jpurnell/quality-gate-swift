import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Detects pipe-buffer deadlock patterns in Foundation `Process` usage.
///
/// The classic deadlock: calling `process.waitUntilExit()` before reading
/// pipe data via `readDataToEndOfFile()`. When the child process produces
/// more output than the ~64 KB pipe buffer, the process blocks on write,
/// `waitUntilExit()` never returns, and the program hangs.
///
/// ## Rules
///
/// - **process.wait-before-read**: `waitUntilExit()` is called before
///   `readDataToEndOfFile()` in the same scope. The fix is to read pipe
///   data first, then wait for exit, or use `ProcessRunner` from QualityGateCore.
public struct ProcessSafetyAuditor: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "process-safety"
    /// Human-readable display name.
    public let name = "Process Safety Auditor"

    /// Creates a new process safety auditor.
    public init() {}

    /// Scans all Swift files under `Sources/` for pipe deadlock patterns.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []

        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: scans Sources/ under cwd only
            allDiagnostics = try auditDirectory(at: sourcesPath)
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .failed
        return CheckResult(checkerId: id, status: status, diagnostics: allDiagnostics, duration: duration)
    }

    private func auditDirectory(at path: String) throws -> [Diagnostic] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return []
        }

        var diagnostics: [Diagnostic] = []
        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            let source = try String(contentsOfFile: fullPath, encoding: .utf8)
            diagnostics.append(contentsOf: auditSource(source, fileName: fullPath))
        }
        return diagnostics
    }

    /// Audits a single source file for pipe deadlock patterns.
    /// - Parameters:
    ///   - source: Swift source code.
    ///   - fileName: File path for diagnostics.
    /// - Returns: Diagnostics for any deadlock patterns found.
    public func auditSource(_ source: String, fileName: String) -> [Diagnostic] {
        let sourceFile = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: sourceFile)
        let sourceLines = source.components(separatedBy: "\n")
        let visitor = ProcessSafetyVisitor(
            filePath: fileName,
            converter: converter,
            sourceLines: sourceLines
        )
        visitor.walk(sourceFile)
        return visitor.diagnostics
    }
}
