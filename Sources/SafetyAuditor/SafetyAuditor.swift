import Foundation
import IndexStoreInfra
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
/// import QualityGateCore
///
/// let config = Configuration()
/// let auditor = SafetyAuditor()
/// let result = try await auditor.check(configuration: config)
/// ```
public struct SafetyAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "SafetyAuditor")

    /// Unique identifier for this checker.
    public let id = "safety"

    /// Human-readable name for this checker.
    public let name = "Safety Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Force unwraps, force casts, `try!`, `fatalError`, OWASP Mobile Top 10 security rules"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.safetySecurity

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Creates a new SafetyAuditor instance.
    public init() {}

    /// Declares this checker cacheable on the whole source tree.
    ///
    /// The verdict is a function of the source and of `swift package describe`, whose answer is
    /// itself a function of `Package.swift` — and the manifests are part of the fingerprint. The
    /// slowest checker in the gate, and it re-ran in full on every invocation until now.
    ///
    /// `wholeSource` is deliberately over-inclusive: over-including an input costs a cache miss,
    /// while under-including one serves a stale pass, which is the only way caching can be
    /// *wrong* rather than merely slow.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSource(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Runs the safety audit over every Swift file the project owns.
    ///
    /// The walk was a hardcoded `Sources/` under the resolved root, so a force unwrap in
    /// `Plugins/`, in `Tests/`, or at the package root passed a gate that forbids force
    /// unwraps unconditionally — the same narrow-scope defect that let six deadlocks sit
    /// under `process-safety` for months. `SourceWalker` is the correction and the reason
    /// pointing at the root is safe: it refuses build output, Xcode containers and
    /// git-ignored trees, so widening the scope does not start auditing vendored code this
    /// repository does not own.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let root = configuration.resolvedProjectRoot
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []

        // Resolved once per run: whether a trap is a defect depends on who calls the target it
        // sits in. An empty map resolves every file to `.executable`, which is the strict
        // reading — a layout we cannot determine gets the rule that assumes an end user is
        // watching.
        //
        // Parsed, not described. `swift package describe` compiles and runs the manifest and
        // resolves the whole dependency graph to do it: surveying nine third-party packages
        // that way wrote 2.7 GB into repositories nobody here owns, to answer a question about
        // four folder names. `parsingManifest` reads `Package.swift` as the Swift source it is,
        // and falls back to SwiftPM's directory convention.
        let targetTypes = TargetTypeMap.parsingManifest(packageRoot: root.path)

        let result = auditFiles(
            scan.files,
            configuration: configuration,
            targetTypes: targetTypes
        )
        allDiagnostics.append(contentsOf: result.diagnostics)
        allOverrides.append(contentsOf: result.overrides)
        if let note = Self.trapNote(counted: result.countedTraps, targetKind: "library, test or plugin") {
            allDiagnostics.append(note)
        }

        // Emitted pass or fail. A checker that examined nothing must not print what a checker
        // that found nothing prints — and this one spent its whole life examining one directory
        // while reporting on a package.
        let plural = scan.files.count == 1 ? "" : "s"
        allDiagnostics.append(Diagnostic(
            severity: .note,
            message: "safety examined \(scan.files.count) file\(plural)"
                + (scan.exclusionClause.map { " · \($0)" } ?? ""),
            ruleId: "safety.coverage"))

        let duration = ContinuousClock.now - startTime
        // A counted trap is a note, and notes do not fail a gate — the status must follow the
        // findings that assert a defect, not the count of the ones that do not.
        let status: CheckResult.Status = allDiagnostics.contains { $0.isViolation } ? .failed : .passed

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
        let status: CheckResult.Status = result.diagnostics.contains { $0.isViolation } ? .failed : .passed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: result.diagnostics,
            overrides: result.overrides,
            duration: duration
        )
    }

    // MARK: - Private Implementation

    /// Audits an already-scoped list of Swift files.
    ///
    /// Takes the file list rather than a directory because deciding *which* files a run owns
    /// is `SourceWalker`'s job, and duplicating that decision here is what produced two
    /// different answers — a private enumerator that honoured `excludePatterns` but not the
    /// git-ignore rule, the default skip list, or Xcode containers. The exclusion filter that
    /// used to live here is applied by the walk, so the local `shouldExclude` / `pathMatches`
    /// pair has gone with it.
    private func auditFiles(
        _ paths: [String],
        configuration: Configuration,
        targetTypes: TargetTypeMap = TargetTypeMap(targets: [])
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride], countedTraps: [String: Int]) {
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        var countedTraps: [String: Int] = [:]

        for path in paths {
            do {
                let source = try String(contentsOfFile: path, encoding: .utf8)
                let result = auditSourceCode(
                    source,
                    fileName: path,
                    configuration: configuration,
                    targetTypes: targetTypes
                )
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
                for (rule, n) in result.countedTraps { countedTraps[rule, default: 0] += n }
            } catch {
                Self.logger.warning("Skipping unreadable source file \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        return (diagnostics, overrides, countedTraps)
    }

    private func auditSourceCode(
        _ source: String,
        fileName: String,
        configuration: Configuration,
        targetTypes: TargetTypeMap = TargetTypeMap(targets: [])
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride], countedTraps: [String: Int]) {
        let sourceFile = Parser.parse(source: source)

        // Run code-safety checks
        let safetyVisitor = SafetyVisitor(
            fileName: fileName,
            source: source,
            exemptionPatterns: configuration.safetyExemptions,
            trapPolicy: configuration.trapPolicy,
            targetType: targetTypes.targetType(forFile: fileName)
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
            overrides: safetyVisitor.overrides + securityVisitor.overrides,
            countedTraps: safetyVisitor.countedTraps
        )
    }

    /// One line stating what was counted rather than reported.
    ///
    /// A checker that examined less than everything must say so — the standing rule this
    /// project applies to `doc-lint`, `doc-code` and `gpu-safety`. Silence here would let a
    /// reader conclude a library has no traps when it has seventy, and a count that *moves* is
    /// the signal worth having.
    ///
    /// - Parameters:
    ///   - counted: Traps not reported, by rule id.
    ///   - targetKind: What kind of target they were found in, for the sentence.
    /// - Returns: The note, or `nil` when nothing was counted — a checker with nothing to say
    ///   should say nothing.
    static func trapNote(counted: [String: Int], targetKind: String) -> Diagnostic? {
        let total = counted.values.reduce(0, +)
        guard total > 0 else { return nil }
        let breakdown = counted
            .sorted { $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
        let plural = total == 1 ? "" : "s"
        let message = "\(total) trap\(plural) in \(targetKind) code counted, not reported "
            + "(\(breakdown)). There the caller is a programmer with a stack trace, and a trap "
            + "is the documented way to report a logic failure. Set `trapPolicy: forbidden` to "
            + "report them, or `justified` to require a stated reason."
        return Diagnostic(
            severity: .note,
            message: message,
            ruleId: "safety.traps-counted"
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

    /// How traps are treated here — see ``TrapPolicy``.
    let trapPolicy: TrapPolicy
    /// The type of the target owning this file, which decides who the caller is.
    let targetType: TargetType
    /// Traps not reported, by rule id. Counted so the run can state what it did not report:
    /// "not a defect" is not the same as "not worth knowing".
    var countedTraps: [String: Int] = [:]

    init(
        fileName: String,
        source: String,
        exemptionPatterns: [String],
        trapPolicy: TrapPolicy = .default,
        targetType: TargetType = .executable
    ) {
        self.fileName = fileName
        self.source = source
        self.exemptionPatterns = exemptionPatterns
        self.sourceLines = source.lines
        self.trapPolicy = trapPolicy
        self.targetType = targetType
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

        // Whether a trap is a defect depends on who the caller is. In an executable the caller
        // is an end user who cannot act on a crash; in a library, test or plugin the caller is
        // a programmer with a stack trace, and trapping on misuse is the language's documented
        // mechanism for a logic failure. A trap naming unfinished work reports either way.
        let trapMessage = Self.messageLiteral(of: node)
        switch trapPolicy.verdict(targetType: targetType, message: trapMessage) {
        case .count:
            countedTraps[ruleId, default: 0] += 1
            return .visitChildren

        case .requireJustification:
            guard !hasJustification(line: line) else { return .visitChildren }
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: message + " Add a `// Justification:` comment stating why this trap is correct here.",
                filePath: fileName,
                lineNumber: line,
                columnNumber: location.column,
                ruleId: ruleId,
                suggestedFix: "// Justification: <why trapping is the right behaviour for this caller>"
            ))
            return .visitChildren

        case .report:
            break
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

    /// The first string literal argument of a trap call, when it has one.
    ///
    /// `precondition(x != y, "Can't advance past endIndex")` → the message. Used to tell a
    /// documented contract from unfinished work.
    static func messageLiteral(of node: FunctionCallExprSyntax) -> String? {
        for argument in node.arguments {
            if let literal = argument.expression.as(StringLiteralExprSyntax.self) {
                return literal.segments.description
            }
        }
        return nil
    }

    /// Whether the line above carries a `// Justification:` comment.
    func hasJustification(line: Int) -> Bool {
        guard line >= 2, line - 2 < sourceLines.count else { return false }
        return sourceLines[line - 2].contains("// Justification:")
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
