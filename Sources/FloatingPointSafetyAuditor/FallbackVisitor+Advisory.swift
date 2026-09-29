import Foundation
import QualityGateCore
import SwiftSyntax

// The rule that cannot be a verdict.
//
// `guard stdDev > 0 else { return 0 }` is correct about zero. It is also what
// runs for a NaN, since a NaN is not greater than anything, and then `0` is an
// answer to a question nobody computed. Whether that answer is right is domain
// knowledge: in one function of the campaign that prompted this, two guards
// four lines apart read the same, and one was right and one was maximally
// wrong. So this reports a question, at `.note`, and lets the author answer it
// once — preferably in the documentation the caller already reads.

/// What a scope knows about the documentation of the value it returns.
enum FallbackDocumentation {
    /// This scope returns on behalf of the one enclosing it.
    case inherited
    /// This scope returns a value of its own, and nothing documents it.
    case undocumented
    /// The text that documents what this scope returns.
    case text(String)
}

extension FallbackVisitor {

    // MARK: - Reading documentation

    /// The documentation comment in `trivia`, one line per element, with the
    /// comment markers removed.
    static func documentationLines(in trivia: Trivia) -> [String] {
        var lines: [String] = []
        for piece in trivia {
            switch piece {
            case .docLineComment(let text):
                lines.append(String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            case .docBlockComment(let text):
                let body = String(text.dropFirst(3).dropLast(2))
                for line in body.lines {
                    var trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("*") {
                        trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    }
                    lines.append(trimmed)
                }
            default:
                continue
            }
        }
        return lines
    }

    /// The `- Returns:` clause of a documentation comment, with its
    /// continuation lines, or nil if there is none.
    static func returnsClause(in trivia: Trivia) -> String? {
        let lines = documentationLines(in: trivia)
        guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix("- returns:") }) else {
            return nil
        }
        var clause = [lines[start]]
        for line in lines[lines.index(after: start)...] {
            if line.isEmpty || line.hasPrefix("- ") { break }
            clause.append(line)
        }
        return clause.joined(separator: " ")
    }

    /// Words that make a sentence a statement about a case rather than a range.
    private static let conditionalWords: Set<String> = [
        "if", "when", "whenever", "unless", "otherwise"
    ]

    /// True if `documentation` names one of `tokens` as what is returned in
    /// some case.
    ///
    /// Two things have to be there: the value, as a word of its own, and a word
    /// that makes the sentence conditional. "A proportion from 0 to 1" has the
    /// first and not the second, and describes a range. "…, or 0 if there is no
    /// total" has both, and is a contract.
    static func names(_ tokens: Set<String>, in documentation: String) -> Bool {
        let words = documentation
            .lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == ".") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let found = Set(words)
        return !found.isDisjoint(with: tokens) && !found.isDisjoint(with: conditionalWords)
    }

    // MARK: - Reading a fallback

    /// A value returned from the `else` of a guard that reads as an answer.
    private struct Claim {
        /// How it is written.
        let display: String
        /// The words documentation could name it by.
        let tokens: Set<String>
    }

    private static let zeroTokens: Set<String> = ["0", "0.0", "zero"]

    /// Reads `expr` as a claim, or returns nil if it is a refusal (`nil`,
    /// `.nan`, `.infinity`) or something computed.
    private func claim(of expr: ExprSyntax, depth: Int = 0) -> Claim? {
        guard depth < 4 else { return nil }
        let display = expr.trimmedDescription

        if let literal = expr.as(IntegerLiteralExprSyntax.self) {
            return Claim(display: display, tokens: Self.tokens(forNumber: literal.literal.text))
        }
        if let literal = expr.as(FloatLiteralExprSyntax.self) {
            return Claim(display: display, tokens: Self.tokens(forNumber: literal.literal.text))
        }
        if let literal = expr.as(BooleanLiteralExprSyntax.self) {
            return Claim(display: display, tokens: [literal.literal.text])
        }
        if let array = expr.as(ArrayExprSyntax.self), array.elements.isEmpty {
            return Claim(display: display, tokens: ["empty"])
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-",
           let inner = claim(of: prefix.expression, depth: depth + 1) {
            return Claim(display: display, tokens: inner.tokens)
        }
        if let member = expr.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "zero" {
            return Claim(display: display, tokens: Self.zeroTokens)
        }
        // `T(0)`, `Double(1)`.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
           FallbackTypes.floatingPointTypeNames.contains(callee.baseName.text)
            || genericNames.contains(callee.baseName.text),
           call.arguments.count == 1,
           let only = call.arguments.first,
           only.label == nil,
           let inner = claim(of: only.expression, depth: depth + 1) {
            return Claim(display: display, tokens: inner.tokens)
        }
        return nil
    }

    /// `0` and `0.0` and `zero` are one value; so are `1` and `1.0`.
    private static func tokens(forNumber text: String) -> Set<String> {
        let digits = text.filter { $0 != "_" }
        var tokens: Set<String> = [digits]
        if digits.hasSuffix(".0") {
            tokens.insert(String(digits.dropLast(2)))
        } else if !digits.contains(".") && !digits.contains("e") && !digits.contains("x") {
            tokens.insert(digits + ".0")
        }
        if !tokens.isDisjoint(with: zeroTokens) {
            tokens.formUnion(zeroTokens)
        }
        return tokens
    }

    // MARK: - Reading a comparison

    /// The value an ordered comparison is *about*, if it is one that could be a
    /// NaN.
    ///
    /// A name with no type of its own takes one from what it is compared with:
    /// `s > T(0)` does not compile unless `s` is a `T`. A bare `0` is no such
    /// evidence, because it is a number in whatever type its neighbour has.
    func comparedSubject(_ lhs: ExprSyntax, _ rhs: ExprSyntax) -> Subject? {
        for (candidate, other) in [(lhs, rhs), (rhs, lhs)] {
            let value = Self.magnitudeArgument(of: candidate) ?? candidate
            guard let key = FallbackSubjectKey.key(of: value, genericNames: genericNames) else {
                continue
            }
            switch evaluate(value) {
            case .carriesNaN(let found):
                if let first = found.first { return first }
            case .unknown:
                switch evaluate(other) {
                case .finite, .carriesNaN:
                    return Subject(key: key, display: value.trimmedDescription)
                case .unknown, .literal:
                    continue
                }
            case .finite, .literal:
                continue
            }
        }
        return nil
    }

    private static let orderedOperators: Set<String> = ["<", "<=", ">", ">="]
    private static let comparisonOperators: Set<String> = ["<", "<=", ">", ">=", "==", "!="]

    /// The ordered comparisons a condition asserts: the condition itself, or
    /// each side of an `&&`. A condition holding an `||` asserts none.
    private func orderedComparisons(in condition: ExprSyntax) -> [(lhs: ExprSyntax, rhs: ExprSyntax)] {
        if let infix = condition.as(InfixOperatorExprSyntax.self),
           let op = infix.operator.as(BinaryOperatorExprSyntax.self),
           Self.orderedOperators.contains(op.operator.text) {
            return [(infix.leftOperand, infix.rightOperand)]
        }
        guard let sequence = condition.as(SequenceExprSyntax.self) else { return [] }

        var segments: [[ExprSyntax]] = [[]]
        for element in sequence.elements {
            if let op = element.as(BinaryOperatorExprSyntax.self) {
                if op.operator.text == "||" { return [] }
                if op.operator.text == "&&" {
                    segments.append([])
                    continue
                }
            }
            segments[segments.count - 1].append(element)
        }

        var found: [(lhs: ExprSyntax, rhs: ExprSyntax)] = []
        for segment in segments where segment.count == 3 {
            guard let op = segment[1].as(BinaryOperatorExprSyntax.self),
                  Self.orderedOperators.contains(op.operator.text) else {
                continue
            }
            found.append((segment[0], segment[2]))
        }
        return found
    }

    /// Learns a name's type from what it is compared with, for the code below.
    func learnFromComparisons(in node: SequenceExprSyntax) {
        let elements = Array(node.elements)
        guard elements.count == 3,
              let op = elements[1].as(BinaryOperatorExprSyntax.self),
              Self.comparisonOperators.contains(op.operator.text) else {
            return
        }
        for (candidate, other) in [(elements[0], elements[2]), (elements[2], elements[0])] {
            guard let reference = candidate.as(DeclReferenceExprSyntax.self) else { continue }
            let name = reference.baseName.text
            let known = kind(ofName: name)
            guard known == nil || known == .other else { continue }
            switch evaluate(other) {
            case .finite, .carriesNaN:
                bind(name, kind: .floatingPoint)
            case .unknown, .literal:
                continue
            }
        }
    }

    /// Thresholds written in place of zero.
    private static let nearZeroMembers: Set<String> = [
        "zero", "ulpOfOne", "leastNonzeroMagnitude", "leastNormalMagnitude"
    ]

    /// `0`, `0.0`, `T(0)`, `.zero`, `T.ulpOfOne`.
    private static func standsForZero(_ expr: ExprSyntax, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }
        if let literal = expr.as(IntegerLiteralExprSyntax.self) {
            return !tokens(forNumber: literal.literal.text).isDisjoint(with: zeroTokens)
        }
        if let literal = expr.as(FloatLiteralExprSyntax.self) {
            return !tokens(forNumber: literal.literal.text).isDisjoint(with: zeroTokens)
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return nearZeroMembers.contains(member.declName.baseName.text)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           call.calledExpression.is(DeclReferenceExprSyntax.self),
           call.arguments.count == 1,
           let only = call.arguments.first,
           only.label == nil {
            return standsForZero(only.expression, depth: depth + 1)
        }
        return false
    }

    // MARK: - Justification

    /// The marker that records a decision about a fallback.
    static let justificationMarker = "// fallback-justified:"

    /// The justification on the line directly above a statement.
    ///
    /// - Returns: The reason given, which may be empty, or nil if there is no
    ///   marker on that line.
    private static func justification(above trivia: Trivia) -> String? {
        var newlines = 0
        for piece in trivia.reversed() {
            switch piece {
            case .spaces, .tabs:
                continue
            case .newlines(let count), .carriageReturnLineFeeds(let count), .carriageReturns(let count):
                newlines += count
                // A blank line between the comment and the statement means the
                // comment is about something else.
                if newlines > 1 { return nil }
            case .lineComment(let text):
                guard let marker = text.range(of: justificationMarker) else { return nil }
                return String(text[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
            default:
                return nil
            }
        }
        return nil
    }

    // MARK: - fallback.guard-returns-a-value

    /// Reports a guard that a NaN fails and that answers with a value.
    func checkGuard(_ node: GuardStmtSyntax) {
        guard let last = node.body.statements.last,
              let returned = last.item.as(ReturnStmtSyntax.self)?.expression,
              let claim = claim(of: returned) else {
            return
        }

        var decided: Subject?
        for condition in node.conditions {
            guard case .expression(let expr) = condition.condition else { continue }
            for comparison in orderedComparisons(in: expr) {
                // Against zero only. `guard x >= lower, x <= upper` states a
                // domain, and outside its domain a density *is* zero.
                guard Self.standsForZero(comparison.lhs) || Self.standsForZero(comparison.rhs) else {
                    continue
                }
                if let subject = comparedSubject(comparison.lhs, comparison.rhs) {
                    decided = subject
                    break
                }
            }
            if decided != nil { break }
        }
        guard let subject = decided else { return }
        guardsExamined += 1

        let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        guard !excludesNaN(subject, before: offset) else { return }

        if let documentation = returnDocumentation(), Self.names(claim.tokens, in: documentation) {
            return
        }

        let location = node.startLocation(converter: converter)
        if let reason = Self.justification(above: node.leadingTrivia) {
            if reason.isEmpty {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: """
                    '\(Self.justificationMarker)' with no reason after it. A justification is a \
                    claim that the fallback was considered, and an empty one claims that without \
                    saying what was concluded.
                    """,
                    filePath: filePath,
                    lineNumber: location.line - 1,
                    columnNumber: 1,
                    ruleId: FallbackRuleID.justificationEmpty,
                    suggestedFix: "Say why '\(claim.display)' is the right answer here, or remove the marker."
                ))
            } else {
                overrides.append(DiagnosticOverride(
                    ruleId: FallbackRuleID.guardReturnsAValue,
                    justification: reason,
                    filePath: filePath,
                    lineNumber: location.line
                ))
                return
            }
        }

        diagnostics.append(Diagnostic(
            severity: .note,
            message: """
            '\(subject.display)' decides this guard, and a NaN fails it: every comparison with one \
            is false. So this returns '\(claim.display)' for a value that was never computed, and \
            '\(claim.display)' is an answer. Whether it is the right one is not something a \
            checker can know. It can know that nothing here says so.
            """,
            filePath: filePath,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: FallbackRuleID.guardReturnsAValue,
            suggestedFix: """
            If '\(claim.display)' is right, name it where the caller reads it: \
            '- Returns: …, or \(claim.display) if …'. If it is not, refuse — return nil, throw, \
            or return a NaN. '\(Self.justificationMarker) <reason>' on the line above records \
            the decision for the checker alone.
            """
        ))
    }
}
