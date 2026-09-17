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
/// - `logging.unguarded-os-import`: `import os`/`import OSLog` outside `#if canImport(os)` guard (error)
final class LoggingVisitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let sourceLines: [String]
    let silentTryKeyword: String
    let allowedSilentTryFunctions: Set<String>
    let loggerNames: Set<String>
    /// Type-or-constructor names whose production counts as handling — see
    /// ``LoggingAuditorConfig/errorValueTypes``.
    let errorValueTypes: [String]
    let isCLI: Bool
    private(set) var diagnostics: [Diagnostic] = []
    private(set) var overrides: [DiagnosticOverride] = []

    private var hasOSImport = false
    private var hasPrintOrNSLog = false
    private var nonApplePlatformDepth = 0
    private var applePlatformDepth = 0

    init(
        fileName: String,
        converter: SourceLocationConverter,
        sourceLines: [String],
        silentTryKeyword: String,
        allowedSilentTryFunctions: Set<String>,
        customLoggerNames: [String],
        errorValueTypes: [String] = [],
        isCLI: Bool = false
    ) {
        self.fileName = fileName
        self.converter = converter
        self.sourceLines = sourceLines
        self.silentTryKeyword = silentTryKeyword
        self.allowedSilentTryFunctions = allowedSilentTryFunctions
        self.errorValueTypes = errorValueTypes
        self.isCLI = isCLI

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
                applePlatformDepth += 1
                if let elements = clause.elements {
                    walk(elements)
                }
                applePlatformDepth -= 1
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
        let pathText = node.path.map { $0.name.text }
        if let first = pathText.first, first == "os" || first == "OSLog" {
            hasOSImport = true

            // Rule 8: flag os/OSLog imports outside #if canImport(os) guard
            if applePlatformDepth == 0 {
                let line = startLine(of: Syntax(node))
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "`import \(first)` is Apple-only; wrap in #if canImport(os) for cross-platform builds",
                    filePath: fileName,
                    lineNumber: line,
                    ruleId: "logging.unguarded-os-import",
                    suggestedFix: "Wrap in #if canImport(os) ... #endif"
                ))
            }
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
                if !isCLI {
                    let line = startLine(of: Syntax(node))
                    if isExempted(line: line, keyword: "logging:") {
    
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
        // A logger call always has a receiver — `logger.error(…)`. An implicit member
        // expression, `.error(…)`, resolves against the contextual type instead, so it is
        // an enum case or a static factory. `MCPToolCallResult.error(message:)` is one,
        // and matching on the method name alone reported nine of them in a package that
        // contains no Logger at all.
        guard memberAccess.base != nil else { return }
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

        if isExempted(line: line, keyword: "logging:") {

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
        if isExempted(line: line, keyword: "logging:") {

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

    /// Whether a `catch` block lets its error vanish.
    ///
    /// ## What was wrong with the old answer
    ///
    /// This asked `bodyText.contains(".\(method)(")` and `bodyText.contains(name)` over the
    /// body's source text. Two consequences, both invisible because a false negative in a
    /// linter produces no output to review:
    ///
    /// - `CellValue.error(_:)` spells the same as `Logger.error(_:)`, so
    ///   `catch { return .error(.value) }` was accepted as logging. It logs nothing.
    /// - `loggerNames` contains the bare string `"log"`, so any body mentioning `catalog`,
    ///   `dialog` or `applyLogic` was accepted too — and that one needs no error-shaped type
    ///   at all.
    ///
    /// Measured across four repositories, **55 of 108 catch blocks in one of them passed this
    /// rule while logging nothing.** It was found by accident: an unrelated refactor removed a
    /// `.error(` from a body and six warnings appeared.
    ///
    /// Rule 4, ninety lines above, already had the insight — *"a logger call always has a
    /// receiver"* — and already said why in a comment. Rule 6 never asked.
    ///
    /// ## The answer now
    ///
    /// Walk the body for real nodes and accept three things: a genuine `throw`, a genuine
    /// logger call, or — when the project has configured it — an error **translated** into a
    /// domain value that the caller receives. See ``LoggingAuditorConfig/errorValueTypes`` for
    /// why the third is not a blanket exemption.
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        let scan = CatchBodyScanner(
            loggerNames: loggerNames,
            logMethodNames: logMethodNames,
            viewMode: .sourceAccurate)
        scan.walk(node.body)

        if scan.throwsAnError || scan.logs {
            return .visitChildren
        }

        if translatesTheError(node.body) {
            return .visitChildren
        }

        let line = startLine(of: Syntax(node))
        if isExempted(line: line, keyword: "logging:") {

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

    /// Whether every exit from a catch body produces a configured error value.
    ///
    /// **Every** exit, not any exit. A block whose one arm returns `.error(.num)` and whose
    /// other returns `nil` is still reported, because the `nil` path is the one the rule is
    /// about — and accepting on "any" would make the clause a blanket exemption for anything
    /// that mentions an error type once.
    ///
    /// Returns `false` when nothing is configured, when the body has no exits at all
    /// (`catch { }` is the shape this rule was written for), or when any exit is a bare
    /// `return`.
    private func translatesTheError(_ body: CodeBlockSyntax) -> Bool {
        guard !errorValueTypes.isEmpty else { return false }

        let scan = ExitScanner(viewMode: .sourceAccurate)
        scan.walk(body)
        guard !scan.exits.isEmpty, !scan.hasValuelessExit else { return false }

        return scan.exits.allSatisfy { expr in
            let text = expr.trimmedDescription
            return errorValueTypes.contains { named in
                // A configured "CellValue.error" is written `.error(…)` at the use site as
                // often as it is spelled in full, so the trailing component has to match too.
                // `ExcelError` names a type and matches on its own.
                if text.contains(named) { return true }
                guard let member = named.split(separator: ".").last, named.contains(".") else {
                    return false
                }
                return text.hasPrefix(".\(member)") || text.contains(".\(member)(")
            }
        }
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
        if isExempted(line: line, keyword: silentTryKeyword) {

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
        if hasPrintOrNSLog && !hasOSImport && !isCLI {
            if isExempted(line: 1, keyword: "logging:") {
                // Exempted — suppress without override record
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

    private func isExempted(line: Int, keyword: String) -> Bool {
        let index0 = line - 1
        if index0 >= 0, index0 < sourceLines.count,
           sourceLines[index0].contains("// \(keyword)") {
            return true
        }
        let prev = index0 - 1
        if prev >= 0, prev < sourceLines.count,
           sourceLines[prev].contains("// \(keyword)") {
            return true
        }
        return false
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
    // MARK: - Catch-body inspection

    /// Looks for a real `throw` and a real logger call inside a catch body.
    ///
    /// Replaces the substring search this rule used to do. Both questions are about nodes:
    /// `throw ` appearing in a comment or a string literal is not a throw, and `.error(…)` with
    /// no receiver is an enum case or a static factory, not a logger.
    private final class CatchBodyScanner: SyntaxVisitor {
        let loggerNames: Set<String>
        let logMethodNames: Set<String>
        private(set) var throwsAnError = false
        private(set) var logs = false

        init(loggerNames: Set<String>, logMethodNames: Set<String>, viewMode: SyntaxTreeViewMode) {
            self.loggerNames = loggerNames
            self.logMethodNames = logMethodNames
            super.init(viewMode: viewMode)
        }

        override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind {
            throwsAnError = true
            return .skipChildren
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            // `NSLog("…")` / `os_log("…")` — a bare call with no receiver, matched by name.
            if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
               callee.baseName.text == "NSLog" || callee.baseName.text == "os_log" {
                logs = true
                return .visitChildren
            }

            guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                  let base = member.base,
                  logMethodNames.contains(member.declName.baseName.text) else {
                return .visitChildren
            }

            // Rule 4 stops at "has a receiver". Rule 6 has to go further: it is deciding
            // whether logging *happened*, not checking the arguments of something already
            // known to be a logger. So the receiver must itself be one — which is what
            // separates `logger.error(…)` from `someValue.log(to: sink)`.
            if receiverIsALogger(base) {
                logs = true
            }
            return .visitChildren
        }

        /// Whether an expression denotes a logger.
        ///
        /// Handles the four spellings the corpus uses: a stored `logger`, a type reference
        /// `Logger.shared`, a logger constructed in place
        /// (`Logger(subsystem:category:).error(…)`), and a logger held in a property named
        /// something else — `Self.fixLogger.error(…)`.
        ///
        /// That last one is why ``namesALogger(_:)`` exists, and it was not anticipated: the
        /// first version of this scanner reported both `Self.fixLogger` sites in
        /// `DocGeneratedFix` as unlogged, where `fixLogger` is
        /// `private static let fixLogger = Logger(…)`. The old substring rule accepted them
        /// because `"fixLogger"` contains `"Logger"` — a coincidence, pointing the right way
        /// for once.
        private func receiverIsALogger(_ expr: ExprSyntax) -> Bool {
            if let reference = expr.as(DeclReferenceExprSyntax.self) {
                return namesALogger(reference.baseName.text)
            }
            if let call = expr.as(FunctionCallExprSyntax.self),
               let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                return namesALogger(callee.baseName.text)
            }
            if let member = expr.as(MemberAccessExprSyntax.self) {
                if namesALogger(member.declName.baseName.text) { return true }
                if let base = member.base { return receiverIsALogger(base) }
                return false
            }
            return false
        }

        /// Whether an identifier names a logger.
        ///
        /// Exact match against the configured names, plus a case-insensitive `"logger"`
        /// **suffix** so a project's own `fixLogger`, `docLogger` or `appLogger` is recognised.
        ///
        /// The suffix is `"logger"` and deliberately not `"log"`: `catalog` and `dialog` both
        /// end in `"log"`, and accepting those would rebuild the false-negative this rule was
        /// just repaired for. A property named `auditLog` is therefore not recognised and needs
        /// its name in `customLoggerNames` — a narrower gap than the alternative, and a stated
        /// one.
        ///
        /// This is a heuristic on a single identifier, which is a different thing from the
        /// heuristic it replaced: that one searched an entire body's source text, so any word
        /// anywhere could satisfy it.
        private func namesALogger(_ identifier: String) -> Bool {
            if loggerNames.contains(identifier) { return true }
            return identifier.lowercased().hasSuffix("logger")
        }
    }

    /// Collects the value each exit from a catch body produces.
    ///
    /// A bare `return` is recorded separately: it produces nothing, so a body containing one
    /// cannot be said to translate its error however its other arms are written.
    private final class ExitScanner: SyntaxVisitor {
        private(set) var exits: [ExprSyntax] = []
        private(set) var hasValuelessExit = false

        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            if let value = node.expression {
                exits.append(value)
            } else {
                hasValuelessExit = true
            }
            return .skipChildren
        }

        override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind {
            exits.append(node.expression)
            return .skipChildren
        }

        // A closure inside the body has its own exits; they answer the closure, not the catch.
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            .skipChildren
        }
    }

}
