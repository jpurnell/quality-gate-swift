import Foundation
import QualityGateCore
import SwiftSyntax

/// SwiftSyntax visitor that detects logging hygiene issues.
///
/// Rules:
/// - `logging.print-statement`: `print()` calls in production code (error)
/// - `logging.silent-try`: `try?` without adjacent logging or suppression comment (warning)
/// - `logging.no-os-logger-import`: File has print/NSLog but no `import os` (warning)
final class LoggingVisitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let sourceLines: [String]
    let silentTryKeyword: String
    let allowedSilentTryFunctions: Set<String>
    let loggerNames: Set<String>
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var overrides: [DiagnosticOverride] = []

    private var hasOSImport = false
    private var hasPrintOrNSLog = false

    init(
        fileName: String,
        converter: SourceLocationConverter,
        sourceLines: [String],
        silentTryKeyword: String,
        allowedSilentTryFunctions: Set<String>,
        customLoggerNames: [String]
    ) {
        self.fileName = fileName
        self.converter = converter
        self.sourceLines = sourceLines
        self.silentTryKeyword = silentTryKeyword
        self.allowedSilentTryFunctions = allowedSilentTryFunctions

        // Built-in logger names + custom ones
        var names: Set<String> = [
            "Logger", "logger", "log",
            "NSLog",
        ]
        for name in customLoggerNames {
            names.insert(name)
        }
        self.loggerNames = names

        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Import tracking

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        // Check if importing `os` or `os.log`
        let pathText = node.path.map { $0.name.text }
        if let first = pathText.first, first == "os" || first == "OSLog" {
            hasOSImport = true
        }
        return .visitChildren
    }

    // MARK: - Rule 1: print-statement + logger name tracking

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Check for bare `print(` calls (Rule 1)
        if let declRef = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = declRef.baseName.text
            if name == "print" || name == "debugPrint" {
                hasPrintOrNSLog = true
                let line = startLine(of: Syntax(node))
                if let override = overrideIfExempted(line: line, keyword: "logging:", ruleId: "logging.print-statement") {
                    overrides.append(override)
                } else {
                    diagnostics.append(Diagnostic(
                        severity: .error,
                        message: "print() should not be used in production code; use os.Logger instead",
                        filePath: fileName,
                        lineNumber: line,
                        ruleId: "logging.print-statement",
                        suggestedFix: "Replace print() with os.Logger"
                    ))
                }
            } else if name == "NSLog" {
                hasPrintOrNSLog = true
            }
        }

        // Check for `NSLog(` via member access too
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            if memberAccess.declName.baseName.text == "NSLog" {
                hasPrintOrNSLog = true
            }
        }

        return .visitChildren
    }

    // MARK: - Rule 2: silent-try

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        // Only interested in try? (not try or try!)
        guard node.questionOrExclamationMark?.tokenKind == .postfixQuestionMark else {
            return .visitChildren
        }

        let line = startLine(of: Syntax(node))

        // Check for allowed fire-and-forget patterns
        let exprText = node.expression.trimmedDescription
        for allowed in allowedSilentTryFunctions {
            if exprText.contains(allowed) {
                return .visitChildren
            }
        }

        // Check for suppression comment
        if let override = overrideIfExempted(line: line, keyword: silentTryKeyword, ruleId: "logging.silent-try") {
            overrides.append(override)
            return .visitChildren
        }

        // Check for adjacent logging call (within +/- 2 lines)
        if hasAdjacentLogging(line: line) {
            return .visitChildren
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "try? silently discards errors without logging",
            filePath: fileName,
            lineNumber: line,
            ruleId: "logging.silent-try",
            suggestedFix: "Wrap in do/catch with error logging, or add // \(silentTryKeyword) <reason>"
        ))

        return .visitChildren
    }

    // MARK: - Rule 3: no-os-logger-import (end of file)

    override func visitPost(_ node: SourceFileSyntax) {
        if hasPrintOrNSLog && !hasOSImport {
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "File contains print()/NSLog() but does not import os; migrate to os.Logger",
                filePath: fileName,
                lineNumber: 1,
                ruleId: "logging.no-os-logger-import",
                suggestedFix: "Add 'import os' and replace print()/NSLog() with os.Logger calls"
            ))
        }
    }

    // MARK: - Helpers

    private func startLine(of node: Syntax) -> Int {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return location.line
    }

    /// Checks if the given line (1-based) or the previous line contains an exemption comment.
    /// Returns a DiagnosticOverride if exempted, nil otherwise.
    private func overrideIfExempted(line: Int, keyword: String, ruleId: String) -> DiagnosticOverride? {
        let index0 = line - 1
        // Check same line
        if index0 >= 0, index0 < sourceLines.count,
           sourceLines[index0].contains("// \(keyword)") {
            return DiagnosticOverride(
                ruleId: ruleId,
                justification: sourceLines[index0].trimmingCharacters(in: .whitespaces),
                filePath: fileName,
                lineNumber: line
            )
        }
        // Check previous line
        let prev = index0 - 1
        if prev >= 0, prev < sourceLines.count,
           sourceLines[prev].contains("// \(keyword)") {
            return DiagnosticOverride(
                ruleId: ruleId,
                justification: sourceLines[prev].trimmingCharacters(in: .whitespaces),
                filePath: fileName,
                lineNumber: line
            )
        }
        return nil
    }

    /// Checks if any line within +/- 2 lines contains a logging call.
    private func hasAdjacentLogging(line: Int) -> Bool {
        let index0 = line - 1
        let range = max(0, index0 - 2)...min(sourceLines.count - 1, index0 + 2)
        for i in range {
            let lineText = sourceLines[i]
            for name in loggerNames {
                if lineText.contains(name) {
                    return true
                }
            }
            // Also check for common patterns like `.error(`, `.warning(`, `.info(`
            // that indicate structured logging
            if lineText.contains(".error(") || lineText.contains(".warning(") ||
               lineText.contains(".info(") || lineText.contains(".notice(") ||
               lineText.contains(".debug(") || lineText.contains(".fault(") {
                return true
            }
        }
        return false
    }
}
