import ExternalInputSyntax
import Foundation
import QualityGateCore
import SwiftSyntax

/// A pattern is a program (`APatternIsAProgram.md`).
///
/// | rule | severity | CWE | reports |
/// |---|---|---|---|
/// | `security.regex-catastrophic` | error | 1333 | A literal pattern with nested or overlapping unbounded repetition — `RegexStructure` |
/// | `security.regex-from-input` | warning | 1333 | A pattern derived from external input — `ExternalInput` |
/// | `security.predicate-injection` | error | 943, 917 | An `NSPredicate` / `NSExpression` format string assembled at runtime |
///
/// **Pattern sites** are the `pattern:` argument of `NSRegularExpression(pattern:…)`, the first
/// argument of `Regex(_:)`, the `of:` argument of a call that also passes `.regularExpression`,
/// and every regex literal. A bare name bound in this file to a plain string literal is followed to
/// that literal, and a catastrophic finding is reported *at the literal*, once.
///
/// `regex-from-input` stays a warning (`TheGateIsNotYetAggressive.md` §2.3): every real site is a
/// feature whose contract is "the caller writes the pattern". What it demands is that the site
/// says what bounds it — so its `// SECURITY:` acknowledgement must, beyond passing
/// `JustificationValidator`, **name a bound**: a cap, limit, maximum, ceiling, deadline or timeout
/// (`namesABound(_:)`). The gate cannot check the bound exists; it can make its absence
/// something a person had to write a false sentence to hide.
extension SecurityVisitor {

    static let regexCatastrophicRule = "security.regex-catastrophic"
    static let regexFromInputRule = "security.regex-from-input"
    static let predicateInjectionRule = "security.predicate-injection"

    // MARK: - Visitor entry points

    /// Every rule here that fires on a call.
    func checkPatternCalls(_ node: FunctionCallExprSyntax) {
        if let pattern = Self.patternArgument(of: node) {
            checkCatastrophic(pattern)
            checkPatternFromInput(pattern, at: node)
        }
        checkPredicate(node)
    }

    /// `/…/` and `#/…/#`: always a pattern, always literal.
    func checkRegexLiteral(_ node: RegexLiteralExprSyntax) {
        reportCatastrophic(in: node.regex.text, at: node)
    }

    // MARK: - Pattern sites

    /// The expression a call compiles as a pattern, if it is a pattern site.
    static func patternArgument(of node: FunctionCallExprSyntax) -> ExprSyntax? {
        let callee = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
        if callee == "NSRegularExpression" {
            return node.arguments.first { $0.label?.text == "pattern" }?.expression
        }
        if callee == "Regex", let first = node.arguments.first, first.label == nil {
            return first.expression
        }
        let regexOption = node.arguments.contains { $0.expression.trimmedDescription.contains(".regularExpression") }
        guard regexOption, node.calledExpression.is(MemberAccessExprSyntax.self) else { return nil }
        return node.arguments.first { $0.label?.text == "of" }?.expression
    }

    // MARK: - regex-catastrophic

    private func checkCatastrophic(_ pattern: ExprSyntax) {
        guard isRuleEnabled(Self.regexCatastrophicRule) else { return }
        if let literal = pattern.as(StringLiteralExprSyntax.self) {
            reportCatastrophic(in: Self.patternText(of: literal), at: literal)
        } else if let name = pattern.as(DeclReferenceExprSyntax.self)?.baseName.text,
                  let literal = Self.literalConstant(named: name, in: pattern.root) {
            reportCatastrophic(in: Self.patternText(of: literal), at: literal)
        }
    }

    private func reportCatastrophic(in pattern: String, at anchor: some SyntaxProtocol) {
        guard isRuleEnabled(Self.regexCatastrophicRule) else { return }
        let location = anchor.startLocation(converter: converter)
        // A constant compiled at two sites is one defect, at the literal.
        let alreadyReported = diagnostics.contains {
            $0.ruleId == Self.regexCatastrophicRule && $0.lineNumber == location.line
                && $0.columnNumber == location.column
        } || overrides.contains { $0.ruleId == Self.regexCatastrophicRule && $0.lineNumber == location.line }
        guard !alreadyReported else { return }
        for finding in RegexStructure.catastrophicGroups(in: pattern) {
            let shape = finding.shape == .nestedRepetition
                ? "repeats a group whose body repeats with no separator"
                : "repeats a group whose alternatives can match the same text"
            report(Diagnostic(
                severity: .error,
                message: "Regular expression \(finding.group.debugDescription) \(shape) — a backtracking "
                    + "engine's running time is exponential in the subject's length. \(Self.citation(Self.regexCatastrophicRule))",
                filePath: fileName,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: Self.regexCatastrophicRule,
                suggestedFix: "Make the inner repetition possessive (a++) or atomic ((?>a+)), remove the inner "
                    + "quantifier, or make the alternatives disjoint"
            ))
        }
    }

    /// The pattern a literal holds, as the engine sees it; each interpolation becomes
    /// `RegexStructure/opaqueAtom`.
    static func patternText(of literal: StringLiteralExprSyntax) -> String {
        if let value = literal.representedLiteralValue { return value }
        let raw = literal.openingPounds != nil
        var text = ""
        for segment in literal.segments {
            if let plain = segment.as(StringSegmentSyntax.self) {
                text += raw ? plain.content.text : unescaped(plain.content.text)
            } else {
                text.append(RegexStructure.opaqueAtom)
            }
        }
        return text
    }

    /// The common escapes of a non-raw string segment. `\u{…}` is kept as written: the analyser
    /// reads it as an escaped literal either way.
    private static func unescaped(_ source: String) -> String {
        var result = ""
        var iterator = source.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "\\", "\"", "'": result.append(next)
            default: result.append("\\"); result.append(next)
            }
        }
        return result
    }

    /// The plain string literal a `let` named `name` is bound to in this file.
    static func literalConstant(named name: String, in root: Syntax) -> StringLiteralExprSyntax? {
        let finder = LiteralConstantFinder(name: name)
        finder.walk(root)
        return finder.literal
    }

    // MARK: - regex-from-input

    private func checkPatternFromInput(_ pattern: ExprSyntax, at call: FunctionCallExprSyntax) {
        guard isRuleEnabled(Self.regexFromInputRule), let trace = externalInput(at: call)?.trace(of: pattern) else {
            return
        }
        reportPatternFromInput(trace, at: call, what: "Regular expression compiled from")
    }

    private func reportPatternFromInput(_ trace: ExternalInput.Trace, at call: FunctionCallExprSyntax, what: String) {
        let location = call.startLocation(converter: converter)
        report(Diagnostic(
            severity: .warning,
            message: "\(what) \(trace.kind.phrase) (\(Self.describe(trace))) — whoever writes the pattern "
                + "chooses how long matching takes. \(Self.citation(Self.regexFromInputRule))",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: Self.regexFromInputRule,
            suggestedFix: "If a literal match was meant, escape it with NSRegularExpression.escapedPattern(for:). "
                + "Otherwise cap the pattern's and the subject's length or match under a deadline, and "
                + "acknowledge with // SECURITY: naming that bound"
        ))
    }

    /// `getString`, via `pattern ← raw`.
    static func describe(_ trace: ExternalInput.Trace) -> String {
        trace.path.isEmpty ? trace.evidence : "\(trace.evidence), via \(trace.path.reversed().joined(separator: " → "))"
    }

    /// The external-input reading of this file, built once.
    private func externalInput(at node: some SyntaxProtocol) -> ExternalInputFile? {
        if let cached = externalInputFile { return cached }
        guard let file = node.root.as(SourceFileSyntax.self) else { return nil }
        let built = ExternalInputFile(file)
        externalInputFile = built
        return built
    }

    // MARK: - predicate-injection, and MATCHES

    private func checkPredicate(_ node: FunctionCallExprSyntax) {
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
              callee == "NSPredicate" || callee == "NSExpression",
              let format = node.arguments.first, format.label?.text == "format" else { return }

        if let literal = format.expression.as(StringLiteralExprSyntax.self),
           !literal.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) {
            checkMatchesOperand(node, format: literal)
            return
        }
        if let name = format.expression.as(DeclReferenceExprSyntax.self)?.baseName.text,
           localStringConstants.contains(name) {
            return
        }
        guard isRuleEnabled(Self.predicateInjectionRule) else { return }
        let isPredicate = callee == "NSPredicate"
        let cwe = isPredicate ? "CWE-943" : "CWE-917"
        let what = isPredicate
            ? "a value in it is parsed as predicate syntax, not compared as data"
            : "the text is parsed as an expression and evaluated"
        let source = externalInput(at: node)?.trace(of: format.expression)
            .map { " The format derives from \($0.kind.phrase) (\(Self.describe($0)))." } ?? ""
        let location = node.startLocation(converter: converter)
        report(Diagnostic(
            severity: .error,
            message: "\(callee) format string assembled at runtime — \(what).\(source) [\(cwe)]",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: Self.predicateInjectionRule,
            suggestedFix: isPredicate
                ? "Keep the format a literal and pass values as %@ arguments and key paths as %K"
                : "Evaluate the formula with a parser that only knows arithmetic, not NSExpression's format language"
        ))
    }

    /// `MATCHES`' right-hand side is a regular expression: a literal format whose arguments are
    /// external is `regex-from-input`.
    private func checkMatchesOperand(_ node: FunctionCallExprSyntax, format: StringLiteralExprSyntax) {
        guard isRuleEnabled(Self.regexFromInputRule),
              let text = format.representedLiteralValue,
              text.range(of: #"\bMATCHES\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let file = externalInput(at: node) else { return }
        for argument in node.arguments.dropFirst() {
            if let trace = file.trace(of: argument.expression) {
                reportPatternFromInput(trace, at: node, what: "NSPredicate MATCHES operand taken from")
                return
            }
        }
    }

    // MARK: - The acknowledgement must name a bound

    /// Words that state a bound: what caps the pattern, the subject, or the time.
    static let boundTerms: Set<String> = [
        "cap", "caps", "capped", "capping", "limit", "limits", "limited", "max", "maximum",
        "ceiling", "deadline", "deadlines", "timeout", "timeouts",
    ]

    /// Whether an acknowledgement's reason names a bound — a word in `boundTerms`, or
    /// "at most", "no more than", `<=`, `≤`.
    static func namesABound(_ reason: String) -> Bool {
        let lowered = reason.lowercased()
        let words = Set(lowered.split(whereSeparator: { !$0.isLetter }).map(String.init))
        guard words.isDisjoint(with: boundTerms) else { return true }
        return ["at most", "no more than", "<=", "≤"].contains { lowered.contains($0) }
    }

    /// Why an otherwise valid acknowledgement of `ruleId` is still not accepted, if it is not.
    static func unmetAcknowledgementRequirement(ruleId: String, reason: String) -> String? {
        guard ruleId == regexFromInputRule, !namesABound(reason) else { return nil }
        return "it names no bound — say what caps the pattern, the subject or the time "
            + "(a cap, limit, maximum, ceiling, deadline or timeout)"
    }
}

/// Finds `let <name> = "<plain literal>"` anywhere in a file.
private final class LiteralConstantFinder: SyntaxVisitor {
    let name: String
    private(set) var literal: StringLiteralExprSyntax?

    init(name: String) {
        self.name = name
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard literal == nil, node.bindingSpecifier.tokenKind == .keyword(.let) else { return .visitChildren }
        for binding in node.bindings {
            guard binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name,
                  let value = binding.initializer?.value.as(StringLiteralExprSyntax.self),
                  !value.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) else { continue }
            literal = value
        }
        return .visitChildren
    }
}
