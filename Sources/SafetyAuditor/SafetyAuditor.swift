import Foundation
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

        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project sources
            let diagnostics = try await auditDirectory(
                at: sourcesPath,
                configuration: configuration
            )
            allDiagnostics.append(contentsOf: diagnostics)
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .failed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
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

        let diagnostics = auditSourceCode(
            source,
            fileName: fileName,
            configuration: configuration
        )

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = diagnostics.isEmpty ? .passed : .failed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    // MARK: - Private Implementation

    private func auditDirectory(
        at path: String,
        configuration: Configuration
    ) async throws -> [Diagnostic] {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return []
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
                let fileDiagnostics = auditSourceCode(
                    source,
                    fileName: fullPath,
                    configuration: configuration
                )
                diagnostics.append(contentsOf: fileDiagnostics)
            } catch {
                // Skip files that can't be read
                continue
            }
        }

        return diagnostics
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
    ) -> [Diagnostic] {
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

        return safetyVisitor.diagnostics + securityVisitor.diagnostics
    }
}

// MARK: - Syntax Visitor

private final class SafetyVisitor: SyntaxVisitor {
    let fileName: String
    let source: String
    let exemptionPatterns: [String]
    let sourceLines: [String]
    var diagnostics: [Diagnostic] = []

    init(fileName: String, source: String, exemptionPatterns: [String]) {
        self.fileName = fileName
        self.source = source
        self.exemptionPatterns = exemptionPatterns
        self.sourceLines = source.components(separatedBy: .newlines)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Force Unwrap Detection

    override func visit(_ node: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
        let location = node.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))
        let line = location.line

        guard !isExempted(line: line) else {
            return .visitChildren
        }

        diagnostics.append(Diagnostic(
            severity: .error,
            message: "Force unwrap detected. This will crash if the value is nil.",
            file: fileName,
            line: line,
            column: location.column,
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

            guard !isExempted(line: line) else {
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Force cast detected. This will crash if the cast fails.",
                file: fileName,
                line: line,
                column: location.column,
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

            guard !isExempted(line: line) else {
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Force try detected. This will crash if an error is thrown.",
                file: fileName,
                line: line,
                column: location.column,
                ruleId: "force-try",
                suggestedFix: "Use do-catch or try? for error handling"
            ))
        }

        return .visitChildren
    }

    // MARK: - Dangerous Function Calls

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // C-style format string detection (handles both DeclReference and MemberAccess callees)
        if isCStyleFormatStringCall(node) {
            let location = node.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))
            let line = location.line

            if !isExempted(line: line) {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "C-style format string call detected. String(format:) bridges to the C printf ABI: %s expects a C string pointer (not Swift String) and will crash at runtime with SIGSEGV. Type errors are caught only at runtime.",
                    file: fileName,
                    line: line,
                    column: location.column,
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

        guard !isExempted(line: line) else {
            return .visitChildren
        }

        switch functionName {
        case "fatalError":
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "fatalError() will crash the application unconditionally.",
                file: fileName,
                line: line,
                column: location.column,
                ruleId: "fatal-error",
                suggestedFix: "Throw an error instead of crashing"
            ))

        case "precondition":
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "precondition() will crash in release builds if the condition is false.",
                file: fileName,
                line: line,
                column: location.column,
                ruleId: "precondition",
                suggestedFix: "Use guard with proper error handling"
            ))

        case "assertionFailure":
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "assertionFailure() indicates a bug and crashes in debug builds.",
                file: fileName,
                line: line,
                column: location.column,
                ruleId: "assertion-failure",
                suggestedFix: "Log the error and handle gracefully, or throw an error"
            ))

        default:
            break
        }

        return .visitChildren
    }

    // MARK: - Unowned Detection

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for modifier in node.modifiers {
            if modifier.name.tokenKind == .keyword(.unowned) {
                let location = modifier.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))
                let line = location.line

                guard !isExempted(line: line) else {
                    return .visitChildren
                }

                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "unowned reference will crash if accessed after the object is deallocated.",
                    file: fileName,
                    line: line,
                    column: location.column,
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

            guard !isExempted(line: line) else {
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .error,
                message: "while true loop may run indefinitely without a break condition.",
                file: fileName,
                line: line,
                column: location.column,
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

    // MARK: - Exemption Checking

    private func isExempted(line: Int) -> Bool {
        // Check same line and previous line for exemption comments
        let linesToCheck = [line - 1, line] // 1-indexed lines
            .filter { $0 >= 1 && $0 <= sourceLines.count }

        for lineNum in linesToCheck {
            let lineContent = sourceLines[lineNum - 1] // Convert to 0-indexed
            for pattern in exemptionPatterns {
                if lineContent.contains(pattern) {
                    return true
                }
            }
        }

        return false
    }
}
