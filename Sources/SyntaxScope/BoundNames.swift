import SwiftSyntax

/// The names a binding pattern introduces.
///
/// Call this on a pattern already known to bind — the pattern of a `let`, of an
/// optional binding, or of a `case let`. `case let .complete(completion)` parses as an
/// expression pattern, so its bindings are `DeclReferenceExpr` nodes rather than
/// `IdentifierPattern`s; the case name itself is the callee and binds nothing.
///
/// For a pattern that may mix bindings with values to match against, use
/// ``bindingNames(inMatching:)``.
public func boundNames(in pattern: some SyntaxProtocol) -> [String] {
    let finder = BindingPatternFinder(viewMode: .sourceAccurate)
    finder.walk(Syntax(pattern))
    return finder.names
}

/// The names bound by a pattern that is matched against a value.
///
/// In `case .loaded(let device, expected)` only `device` is a binding; `expected` is a
/// value the subject is compared with. An identifier pattern always binds, and
/// everything under a `let` / `var` binds (`boundNames(in:)`); a bare reference
/// elsewhere in the pattern does not.
public func bindingNames(inMatching pattern: some SyntaxProtocol) -> [String] {
    let finder = MatchedPatternFinder(viewMode: .sourceAccurate)
    finder.walk(Syntax(pattern))
    return finder.names
}

/// The names a list of conditions binds: `if let x`, `guard let x = y`,
/// `while case let .some(x) = next`.
public func boundNames(in conditions: ConditionElementListSyntax) -> [String] {
    var names: [String] = []
    for element in conditions {
        switch element.condition {
        case .optionalBinding(let binding):
            names.append(contentsOf: boundNames(in: binding.pattern))
        case .matchingPattern(let matching):
            names.append(contentsOf: bindingNames(inMatching: matching.pattern))
        case .expression, .availability:
            continue
        }
    }
    return names
}

/// The names a closure introduces for its own body: its parameters and its
/// capture-list entries.
///
/// `[log]` and `[log = self.log]` both bind `log` to a value fixed when the closure
/// is created. `[weak self]` is left out: it rebinds the keyword, not a name.
public func boundNames(of closure: ClosureExprSyntax) -> [String] {
    var names: [String] = []
    guard let signature = closure.signature else { return names }
    if let capture = signature.capture {
        for item in capture.items {
            if let name = boundName(of: item) { names.append(name) }
        }
    }
    switch signature.parameterClause {
    case .simpleInput(let shorthand):
        for parameter in shorthand { names.append(parameter.name.text) }
    case .parameterClause(let clause):
        for parameter in clause.parameters {
            names.append((parameter.secondName ?? parameter.firstName).text)
        }
    case .none:
        break
    }
    return names
}

/// The name one capture-list entry binds, or `nil` for a capture of `self`.
public func boundName(of capture: ClosureCaptureSyntax) -> String? {
    if let name = capture.name {
        return name.tokenKind == .keyword(.self) ? nil : name.text
    }
    guard let reference = capture.expression.as(DeclReferenceExprSyntax.self),
          reference.baseName.tokenKind != .keyword(.self) else { return nil }
    return reference.baseName.text
}

/// The parameter names a function-like declaration binds in its body.
public func boundNames(in parameters: FunctionParameterListSyntax) -> [String] {
    parameters.map { ($0.secondName ?? $0.firstName).text }
}

/// Walks a pattern known to bind and collects every name in it.
private final class BindingPatternFinder: SyntaxVisitor {
    var names: [String] = []
    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.append(node.identifier.text)
        return .skipChildren
    }
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if let base = node.base { walk(base) }
        return .skipChildren
    }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        for argument in node.arguments { walk(Syntax(argument)) }
        return .skipChildren
    }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        names.append(node.baseName.text)
        return .skipChildren
    }
}

/// Walks a pattern matched against a value and collects only what it binds.
private final class MatchedPatternFinder: SyntaxVisitor {
    var names: [String] = []
    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.append(node.identifier.text)
        return .skipChildren
    }
    override func visit(_ node: ValueBindingPatternSyntax) -> SyntaxVisitorContinueKind {
        names.append(contentsOf: boundNames(in: node.pattern))
        return .skipChildren
    }
}
