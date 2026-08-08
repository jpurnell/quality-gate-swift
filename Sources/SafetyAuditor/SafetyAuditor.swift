import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source files for forbidden patterns.
///
/// Forbidden patterns include:
/// - Force unwraps (`!`)
/// - Force casts (`as!`)
/// - Force try (`try!`)
/// - `fatalError()`
/// - `precondition()`
/// - `unowned`
/// - `assertionFailure()`
/// - `while true`
/// - C-style format strings (`String(format:)`, `NSString(format:)`,
///   `NSString.localizedStringWithFormat`)
///
/// ## Usage
///
/// ```swift
/// let auditor = SafetyAuditor()
/// let result = try await auditor.check(configuration: config)
/// ```
public struct SafetyAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "SafetyAuditor")

    /// Unique identifier for this checker.
    public let id = "safety"

    /// Human-readable name for this checker.
    public let name = "Safety Auditor"

    /// Creates a new SafetyAuditor instance.
    public init() {}

    /// Run the safety audit on the current directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        // Find all Swift files in Sources/
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []

        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project sources
            let result = try await auditDirectory(
                at: sourcesPath,
                configuration: configuration
            )
            allDiagnostics.append(contentsOf: result.diagnostics)
            allOverrides.append(contentsOf: result.overrides)
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .failed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            overrides: allOverrides,
            duration: duration
        )
    }

    /// Audit a single source code string.
    ///
    /// - Parameters:
    ///   - source: The Swift source code to audit.
    ///   - fileName: The name of the file (for diagnostics).
    ///   - configuration: The project configuration.
    /// - Returns: A check result with any violations found.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let result = auditSourceCode(
            source,
            fileName: fileName,
            configuration: configuration
        )

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = result.diagnostics.isEmpty ? .passed : .failed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: result.diagnostics,
            overrides: result.overrides,
            duration: duration
        )
    }

    // MARK: - Private Implementation

    private func auditDirectory(
        at path: String,
        configuration: Configuration
    ) async throws -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return ([], [])
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            // Check exclude patterns
            if shouldExclude(path: fullPath, patterns: configuration.excludePatterns) {
                continue
            }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let result = auditSourceCode(
                    source,
                    fileName: fullPath,
                    configuration: configuration
                )
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
            } catch {
                Self.logger.warning("Skipping unreadable source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        return (diagnostics, overrides)
    }

    private func shouldExclude(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if pathMatches(path: path, pattern: pattern) {
                return true
            }
        }
        return false
    }

    private func pathMatches(path: String, pattern: String) -> Bool {
        // Simple glob matching for common patterns
        if pattern.contains("**") {
            let component = pattern.replacingOccurrences(of: "**/", with: "")
                .replacingOccurrences(of: "/**", with: "")
            return path.contains(component)
        }
        return path.contains(pattern.replacingOccurrences(of: "*", with: ""))
    }

    private func auditSourceCode(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let sourceFile = Parser.parse(source: source)

        // Run code-safety checks
        let safetyVisitor = SafetyVisitor(
            fileName: fileName,
            source: source,
            exemptionPatterns: configuration.safetyExemptions
        )
        safetyVisitor.walk(sourceFile)

        // Run security checks
        let securityExemptions = configuration.safetyExemptions + ["// SECURITY:"]
        let securityVisitor = SecurityVisitor(
            fileName: fileName,
            source: source,
            exemptionPatterns: securityExemptions,
            configuration: configuration.security
        )
        securityVisitor.walk(sourceFile)

        return (
            diagnostics: safetyVisitor.diagnostics + securityVisitor.diagnostics,
            overrides: safetyVisitor.overrides + securityVisitor.overrides
        )
    }
}

// MARK: - Syntax Visitor

private final class SafetyVisitor: SyntaxVisitor {
    let fileName: String
    let source: String
    let exemptionPatterns: [String]
    let sourceLines: [String]
    var diagnostics: [Diagnostic] = []
    var overrides: [DiagnosticOverride] = []

    init(fileName: String, source: String, exemptionPatterns: [String]) {
        self.fileName = fileName
        self.source = source
        self.exemptionPatterns = exemptionPatterns
        self.sourceLines = source.lines
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Force Unwrap Detection

    override func visit(_ node: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
        let location = node.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))
        let line = location.line

        if isExempted(line: line) {
            return .visitChildren
        }

        diagnostics.append(Diagnostic(
            severity: .error,
            message: "Force unwrap detected. This will crash if the value is nil.",
            filePath: fileName,
            lineNumber: line,
            columnNumber: location.column,
            ruleId: "force-unwrap",
            suggestedFix: "Use optional binding (if let/guard let) or nil coalescing (??)"
        ))

        return .visitChildren
    }

    // MARK: - Force Cast Detection

    // Note: SwiftSyntax Parser produces UnresolvedAsExprSyntax, not AsExprSyntax.
    // AsExprSyntax only exists after OperatorTable.foldAll() is called.
    override func visit(_ node: UnresolvedAsExprSyntax) -> SyntaxVisitorContinueKind {
        // Check if this is a force cast (as!)
        if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
            let location = node.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))
            let line = location.line

            if isExempted(line: line) {
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Force cast detected. This will crash if the cast fails.",
                filePath: fileName,
                lineNumber: line,
                columnNumber: location.column,
                ruleId: "force-cast",
                suggestedFix: "Use conditional cast (as?) with optional binding"
            ))
        }

        return .visitChildren
    }

    // MARK: - Force Try Detection

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        // Check if this is a force try (try!)
        if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
            let location = node.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))
            let line = location.line

            if isExempted(line: line) {
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Force try detected. This will crash if an error is thrown.",
                filePath: fileName,
                lineNumber: line,
                columnNumber: location.column,
                ruleId: "force-try",
                suggestedFix: "Use do-catch or try? for error handling"
            ))
        }

        return .visitChildren
    }

    // MARK: - Dangerous Function Calls

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Splitting text into lines in a way that mishandles CRLF. See `newlineSplitKind`.
        if let kind = newlineSplitKind(node) {
            let location = node.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))
            let line = location.line

            if !isExempted(line: line) {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: kind.message,
                    filePath: fileName,
                    lineNumber: line,
                    columnNumber: location.column,
                    ruleId: "newline-split",
                    suggestedFix: kind.suggestedFix
                ))
            }
        }

        // C-style format string detection (handles both DeclReference and MemberAccess callees)
        if isCStyleFormatStringCall(node) {
            let location = node.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))
            let line = location.line

            if isExempted(line: line) {
                // SAFETY comment suppresses without creating override
            } else {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "C-style format string call detected. String(format:) bridges to the C printf ABI: %s expects a C string pointer (not Swift String) and will crash at runtime with SIGSEGV. Type errors are caught only at runtime.",
                    filePath: fileName,
                    lineNumber: line,
                    columnNumber: location.column,
                    ruleId: "c-style-format-string",
                    suggestedFix: "Use string interpolation \"\\(value)\", or value.formatted(), or value.formatted(.number.precision(.fractionLength(N))) for decimal places, or String.padding(toLength:withPad:startingAt:) for column alignment. See development-guidelines/00_CORE_RULES/01_CODING_RULES.md §3.7."
                ))
            }
        }

        let functionName: String

        if let identifierExpr = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            functionName = identifierExpr.baseName.text
        } else {
            return .visitChildren
        }

        let location = node.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))
        let line = location.line

        let ruleId: String
        let message: String
        let suggestedFix: String

        switch functionName {
        case "fatalError":
            ruleId = "fatal-error"
            message = "fatalError() will crash the application unconditionally."
            suggestedFix = "Throw an error instead of crashing"

        case "precondition":
            ruleId = "precondition"
            message = "precondition() will crash in release builds if the condition is false."
            suggestedFix = "Use guard with proper error handling"

        case "assertionFailure":
            ruleId = "assertion-failure"
            message = "assertionFailure() indicates a bug and crashes in debug builds."
            suggestedFix = "Log the error and handle gracefully, or throw an error"

        default:
            return .visitChildren
        }

        if isExempted(line: line) {
            return .visitChildren
        }

        diagnostics.append(Diagnostic(
            severity: .error,
            message: message,
            filePath: fileName,
            lineNumber: line,
            columnNumber: location.column,
            ruleId: ruleId,
            suggestedFix: suggestedFix
        ))

        return .visitChildren
    }

    // MARK: - Unowned Detection

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for modifier in node.modifiers {
            if modifier.name.tokenKind == .keyword(.unowned) {
                let location = modifier.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))
                let line = location.line

                if isExempted(line: line) {
                    return .visitChildren
                }

                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "unowned reference will crash if accessed after the object is deallocated.",
                    filePath: fileName,
                    lineNumber: line,
                    columnNumber: location.column,
                    ruleId: "unowned",
                    suggestedFix: "Use weak reference with guard let, or justify the lifecycle guarantee with // SAFETY:"
                ))
            }
        }

        return .visitChildren
    }

    // MARK: - Infinite Loop Detection

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        // Check if the condition is `true`
        if let boolLiteral = node.conditions.first?.condition.as(BooleanLiteralExprSyntax.self),
           boolLiteral.literal.tokenKind == .keyword(.true) {

            let location = node.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))
            let line = location.line

            if isExempted(line: line) {
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .error,
                message: "while true loop may run indefinitely without a break condition.",
                filePath: fileName,
                lineNumber: line,
                columnNumber: location.column,
                ruleId: "infinite-loop",
                suggestedFix: "Add a break condition or use a different loop construct"
            ))
        }

        return .visitChildren
    }

    // MARK: - C-Style Format String Helpers

    private func isCStyleFormatStringCall(_ node: FunctionCallExprSyntax) -> Bool {
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
           (ref.baseName.text == "String" || ref.baseName.text == "NSString"),
           hasFormatArgument(node) {
            return true
        }

        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "localizedStringWithFormat",
           let base = member.base?.as(DeclReferenceExprSyntax.self),
           base.baseName.text == "NSString" {
            return true
        }

        return false
    }

    private func hasFormatArgument(_ node: FunctionCallExprSyntax) -> Bool {
        guard let first = node.arguments.first else { return false }
        return first.label?.text == "format"
    }

    /// How a call gets line-splitting wrong, if it does.
    ///
    /// Three spellings, three different wrong answers, and they are worth telling apart because
    /// the obvious fix for one of them *is* another one.
    ///
    /// `"\r\n"` is a single `Character` in Swift — one extended grapheme cluster — but only
    /// `split(separator:)` compares whole `Character`s. `components(separatedBy: String)`
    /// searches by scalar and so does find the `\n` inside a `\r\n`. And `CharacterSet.newlines`
    /// treats the `\r` and the `\n` as two separators in a row. Hence:
    ///
    /// | Written as | `"a\r\nb"` becomes |
    /// | --- | --- |
    /// | `split(separator: "\n")` | `["a\r\nb"]` — the whole document, one element |
    /// | `components(separatedBy: "\n")` | `["a\r", "b"]` — a stray return on every line |
    /// | `components(separatedBy: .newlines)` | `["a", "", "b"]` — an empty line per CRLF |
    /// | `split(whereSeparator: \.isNewline)` | `["a", "b"]` |
    ///
    /// The third is the trap that catches people fixing the first two: it looks like the
    /// Unicode-aware answer and silently doubles the line count of a Windows file, which shifts
    /// every line number reported against it.
    ///
    /// Only literal separators are matched. Resolving a variable needs type information this
    /// visitor does not have, and guessing would cost a false positive on every `split` in a
    /// codebase.
    private func newlineSplitKind(_ node: FunctionCallExprSyntax) -> NewlineSplitKind? {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else {
            return nil
        }

        let separatorLabel: String
        switch member.declName.baseName.text {
        case "split": separatorLabel = "separator"
        case "components": separatorLabel = "separatedBy"
        default: return nil
        }

        guard let argument = node.arguments.first(where: { $0.label?.text == separatorLabel })
        else { return nil }

        // `components(separatedBy: .newlines)` — the plausible-looking one.
        if separatorLabel == "separatedBy",
           let set = argument.expression.as(MemberAccessExprSyntax.self),
           set.base == nil,
           ["newlines", "whitespacesAndNewlines"].contains(set.declName.baseName.text) {
            return .newlineCharacterSet
        }

        guard let literal = argument.expression.as(StringLiteralExprSyntax.self) else {
            return nil
        }

        // An escape sequence is its own segment — `"\n"` parses as the escape plus an empty
        // trailing segment — so the pieces are rejoined rather than counted. An interpolation
        // is not a segment at all, and a separator built at runtime is out of reach here.
        var literalText = ""
        for segment in literal.segments {
            guard let text = segment.as(StringSegmentSyntax.self) else { return nil }
            literalText += text.content.text
        }
        guard Self.newlineSeparators.contains(literalText) else { return nil }

        return separatorLabel == "separator" ? .characterSplit : .stringComponents
    }

    /// Separator literals that mean "a newline", in both source spellings.
    ///
    /// `content.text` is the *source* text, so an escaped newline arrives as the two characters
    /// `\` and `n`. A raw string or a multiline literal can carry the real character instead.
    private static let newlineSeparators: Set<String> = [
        #"\n"#, #"\r"#, #"\r\n"#,
        "\n", "\r", "\r\n"
    ]

    // MARK: - Exemption Checking

    private func isExempted(line: Int) -> Bool {
        let linesToCheck = [line - 1, line]
            .filter { $0 >= 1 && $0 <= sourceLines.count }
        for lineNum in linesToCheck {
            let lineContent = sourceLines[lineNum - 1]
            for pattern in exemptionPatterns {
                if lineContent.contains(pattern) {
                    return true
                }
            }
        }
        return false
    }
}

/// How a line-splitting call mishandles CRLF.
///
/// Separate cases because the three go wrong in three different ways, and because the tempting
/// fix for the first two is the third.
private enum NewlineSplitKind {

    /// `split(separator: "\n")` — matches whole `Character`s, and `"\r\n"` is one of them.
    case characterSplit

    /// `components(separatedBy: "\n")` — finds the `\n` inside a `\r\n` and leaves the `\r`.
    case stringComponents

    /// `components(separatedBy: .newlines)` — counts the `\r` and the `\n` as two separators.
    case newlineCharacterSet

    /// What went wrong, in terms of what the code will actually produce.
    var message: String {
        switch self {
        case .characterSplit:
            return "Text split on a newline literal. \"\\r\\n\" is a single Character in Swift — one extended grapheme cluster — and split(separator:) compares whole Characters, so it does not match. A file written on Windows comes back as ONE element containing the whole document. Nothing throws; the first symptom appears somewhere else entirely."
        case .stringComponents:
            return "Lines split on a newline literal. components(separatedBy:) searches by scalar, so it does find the \\n inside a \\r\\n — but it leaves the \\r on the end of every line. Comparisons, suffix checks and column arithmetic are then all one character out on any file written on Windows."
        case .newlineCharacterSet:
            return "Lines split on CharacterSet.newlines. The set contains both \\r and \\n, so a \\r\\n counts as two separators in a row and yields an empty element between every pair of lines — doubling the line count of a file written on Windows and shifting every line number reported against it."
        }
    }

    /// The replacement that is right for all four line endings.
    ///
    /// `.isNewline` is a property of `Character`, so a `\r\n` is one separator rather than two,
    /// and CR, LF, CRLF, NEL and the Unicode line separators all match.
    var suggestedFix: String {
        let escape = "If one specific terminator really is meant — a wire protocol that "
            + "specifies it — say so with a // SAFETY: comment."
        switch self {
        case .characterSplit:
            return "Use split(whereSeparator: \\.isNewline). " + escape
        case .stringComponents, .newlineCharacterSet:
            return "Use split(omittingEmptySubsequences: false, whereSeparator: \\.isNewline), which keeps blank lines exactly as components(separatedBy: \"\\n\") did. Do NOT reach for components(separatedBy: .newlines) — it inserts an empty element for every CRLF. " + escape
        }
    }
}
