import Foundation
import IndexStoreInfra
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

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Pipe-buffer deadlock: waitUntilExit() before reading pipe output"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.correctness

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Creates a new process safety auditor.
    public init() {}

    /// Scans every Swift file under the project root for pipe deadlock patterns.
    ///
    /// Previously this walked a hardcoded `Sources/` and ignored `configuration` entirely, so it
    /// had never examined `Tests/` or `Plugins/` — and a deadlock hangs a test suite exactly as
    /// thoroughly as it hangs the tool. It also read each file with a throwing call inside the
    /// walk, so one unreadable file aborted the entire scan. Both are corrected here: the walk
    /// comes from `SourceWalker`, which honours the configured exclusions and the shared skip
    /// list, and an unreadable file is skipped rather than fatal.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let files = SourceWalker.swiftFiles(under: root, excludePatterns: configuration.excludePatterns)

        var allDiagnostics: [Diagnostic] = []
        for path in files {
            // silent: an unreadable file must not abort the walk, as a throwing read once did.
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            allDiagnostics.append(contentsOf: auditSource(source, fileName: path))
        }

        // Emitted pass or fail. This checker's silence was once read as "subprocesses here cannot
        // hang", when it meant "nobody wrote the one shape it matches" — and it matches exactly
        // one. Saying so is the difference between a guarantee and a scope.
        allDiagnostics.append(Diagnostic(
            severity: .note,
            message: "process-safety examined \(files.count) files for 1 rule "
                + "(process.wait-before-read); unbounded reads are the separate concern of bounded-io",
            ruleId: "process-safety.coverage"))

        let duration = ContinuousClock.now - startTime
        // Any finding fails, note excepted. This checker reports at `.warning`, so testing for
        // `.error` alone would pass a file containing the very deadlock it exists to detect —
        // which is precisely what happened when the coverage note was first added here, and it
        // silently downgraded six real findings the widened walk had just uncovered.
        let failed = allDiagnostics.contains { $0.severity != .note }
        return CheckResult(checkerId: id, status: failed ? .failed : .passed, diagnostics: allDiagnostics, duration: duration)
    }

    /// Audits a single source file for pipe deadlock patterns.
    /// - Parameters:
    ///   - source: Swift source code.
    ///   - fileName: File path for diagnostics.
    /// - Returns: Diagnostics for any deadlock patterns found.
    public func auditSource(_ source: String, fileName: String) -> [Diagnostic] {
        let sourceFile = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: sourceFile)
        let sourceLines = source.lines
        let visitor = ProcessSafetyVisitor(
            filePath: fileName,
            converter: converter,
            sourceLines: sourceLines
        )
        visitor.walk(sourceFile)
        return visitor.diagnostics
    }
}
