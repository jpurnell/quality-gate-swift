import Foundation
import QualityGateCore
import SwiftSyntax

/// SwiftSyntax visitor that detects logging hygiene issues.
///
/// Rules:
/// - `logging.print-statement`: `print()` calls in production code (error)
/// - `logging.silent-try`: `try?` without adjacent logging or suppression comment (warning)
/// - `logging.no-os-logger-import`: File has print/NSLog but no `import os` (warning)
/// - `logging.missing-privacy`: Logger call with interpolation but no `privacy:` annotation (warning)
/// - `logging.bare-logger-init`: `Logger()` with no subsystem/category (note)
/// - `logging.catch-without-logging`: `catch` block with no logger call and no `throw` (warning)
/// - `logging.privacy-in-fallback`: `privacy:` annotation inside non-Apple `#else` block (error)
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
    private var nonApplePlatformDepth = 0

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

    // MARK: - Platform-conditional tracking

    private static let appleImportConditions: Set<String> = ["canImport(os)", "canImport(OSLog)"]

    private func isApplePlatformCondition(_ condition: ExprSyntax) -> Bool {
        let text = condition.trimmedDescription
        return Self.appleImportConditions.contains(text)
    }

    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        let clauses = node.clauses
        guard let firstClause = clauses.first,
              let condition = firstClause.condition,
              isApplePlatformCondition(condition) else {
            return .visitChildren
        }

        for clause in clauses {
            let isAppleBranch = clause.condition.map { isApplePlatformCondition($0) } ?? false
            if isAppleBranch {
                if let elements = clause.elements {
                    walk(elements)
                }
            } else {
                nonApplePlatformDepth += 1
                if let elements = clause.elements {
                    walk(elements)
                }
                nonApplePlatformDepth -= 1
            }
        }

        return .skipChildren
    }

    /// Whether the visitor is currently inside a non-Apple platform block.
    private var isInNonAppleFallback: Bool { nonApplePlatformDepth > 0 }

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

        checkMissingPrivacy(node)
        checkBareLoggerInit(node)

        return .visitChildren
    }

    // MARK: - Rule 4: missing-privacy

    private let logMethodNames: Set<String> = [
        "debug", "info", "notice", "warning", "error", "fault", "log",
    ]

    /// Checks logger method calls for interpolation segments missing `privacy:` annotations.
    /// Also detects `privacy:` usage inside non-Apple fallback blocks (Rule 7).
    private func checkMissingPrivacy(_ node: FunctionCallExprSyntax) {
        guard let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) else { return }
        let methodName = memberAccess.declName.baseName.text
        guard logMethodNames.contains(methodName) else { return }

        guard let firstArg = node.arguments.first else { return }
        let argText = firstArg.expression.trimmedDescription

        guard argText.contains("\\(") else { return }

        let line = startLine(of: Syntax(node))

        if isInNonAppleFallback {
            checkPrivacyInFallback(argText: argText, line: line)
            return
        }

        if let override = overrideIfExempted(line: line, keyword: "logging:", ruleId: "logging.missing-privacy") {
            overrides.append(override)
            return
        }

        let segments = argText.components(separatedBy: "\\(")
        for segment in segments.dropFirst() {
            if !segment.contains("privacy:") {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Logger call contains interpolation without privacy: annotation",
                    filePath: fileName,
                    lineNumber: line,
                    ruleId: "logging.missing-privacy",
                    suggestedFix: "Add privacy: .public or privacy: .private to each interpolated value"
                ))
                return
            }
        }
    }

    // MARK: - Rule 7: privacy-in-fallback

    /// Flags `privacy:` annotations inside non-Apple fallback blocks where they won't compile.
    private func checkPrivacyInFallback(argText: String, line: Int) {
        let segments = argText.components(separatedBy: "\\(")
        for segment in segments.dropFirst() {
            if segment.contains("privacy:") {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "privacy: annotation used in non-Apple platform fallback — will not compile on Linux",
                    filePath: fileName,
                    lineNumber: line,
                    ruleId: "logging.privacy-in-fallback",
                    suggestedFix: "Remove privacy: annotations from logger calls in #else blocks; privacy: is only valid with Apple's os.Logger"
                ))
                return
            }
        }
    }

    // MARK: - Rule 5: bare-logger-init

    private func checkBareLoggerInit(_ node: FunctionCallExprSyntax) {
        guard let declRef = node.calledExpression.as(DeclReferenceExprSyntax.self),
              declRef.baseName.text == "Logger",
              node.arguments.isEmpty else { return }

        let line = startLine(of: Syntax(node))
        if let override = overrideIfExempted(line: line, keyword: "logging:", ruleId: "logging.bare-logger-init") {
            overrides.append(override)
            return
        }

        diagnostics.append(Diagnostic(
            severity: .note,
            message: "Logger() has no subsystem or category — logs will be hard to filter",
            filePath: fileName,
            lineNumber: line,
            ruleId: "logging.bare-logger-init",
            suggestedFix: "Use Logger(subsystem: Bundle.main.bundleIdentifier ?? \"com.app\", category: \"TypeName\")"
        ))
    }

    // MARK: - Rule 6: catch-without-logging

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        let bodyText = node.body.statements.trimmedDescription

        if bodyText.contains("throw ") {
            return .visitChildren
        }

        for name in loggerNames {
            if bodyText.contains(name) {
                return .visitChildren
            }
        }
        for method in logMethodNames {
            if bodyText.contains(".\(method)(") {
                return .visitChildren
            }
        }

        let line = startLine(of: Syntax(node))
        if let override = overrideIfExempted(line: line, keyword: "logging:", ruleId: "logging.catch-without-logging") {
            overrides.append(override)
            return .visitChildren
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "catch block neither logs the error nor rethrows",
            filePath: fileName,
            lineNumber: line,
            ruleId: "logging.catch-without-logging",
            suggestedFix: "Add logger.error() or logger.warning() call, or rethrow the error"
        ))

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
            if let exempt = overrideIfExempted(line: 1, keyword: "logging:", ruleId: "logging.no-os-logger-import") {
                overrides.append(exempt)
            } else {
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
