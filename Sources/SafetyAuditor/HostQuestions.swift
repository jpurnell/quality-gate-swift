import ExternalInputSyntax
import Foundation
import SwiftSyntax

// MARK: - Host questions in one function

/// What one function asks about hosts, and what it hands URLs to for checking.
struct HostFacts {
    struct Question {
        /// The URL the question is about, by the name it goes by.
        let root: String
        let position: AbsolutePosition
    }

    struct Check {
        let root: String
        let slot: RequestSlot
        let position: AbsolutePosition
        /// The call is in a `guard` / `if` / `while` condition or is a `try` statement: the
        /// callee can refuse. A check only if the join finds the callee to be a host validator.
        let guards: Bool
        /// The call's result is compared with something. A check only if the join finds the
        /// callee to carry its parameter's host into what it returns.
        let compared: Bool
    }

    var questions: [Question] = []
    var checks: [Check] = []
}

/// What a value made from URLs carries of their hosts (`AURLIsNotARequest.md` §12.2).
struct HostCarry {
    /// URLs whose host is in the value: `url` for `Endpoint(host: url.host)`, `(url.scheme, url.host)`.
    var roots: [String] = []
    /// URLs handed whole to a call — `Origin(url)`. The host is in the value only if the join
    /// finds that the callee carries it.
    var calls: [Call] = []

    struct Call {
        let root: String
        let slot: RequestSlot
    }

    var isEmpty: Bool { roots.isEmpty && calls.isEmpty }

    mutating func merge(_ other: HostCarry) {
        for root in other.roots where !roots.contains(root) {
            roots.append(root)
        }
        calls += other.calls
    }
}

/// What the names bound in one function stand for, as far as a host is concerned.
struct HostNames {
    /// `host` → `url`, for `let host = url.host?.lowercased()` and for a name bound to that one.
    var hosts: [String: String] = [:]
    /// `mine` → what it carries, for `let mine = Endpoint(host: url.host)`, a tuple, `Origin(url)`.
    var carried: [String: HostCarry] = [:]
    /// `components` → `url`, for `let components = URLComponents(url: url, …)`.
    var derived: [String: String] = [:]

    /// `root`, and each URL it was made from: a question asked of the components of a URL is
    /// asked of the URL.
    func urls(of root: String) -> [String] {
        var found = [root]
        var current = root
        // Bounded: nobody re-wraps a URL this many times.
        for _ in 0..<4 {
            guard let next = derived[current], !found.contains(next) else { break }
            found.append(next)
            current = next
        }
        return found
    }
}

/// Reads what an expression carries of a URL's host.
enum HostCarrying {
    typealias Callee = (FunctionCallExprSyntax) -> String?

    /// Types that hold the URL they are constructed from.
    private static let holders: Set<String> = [
        "URLComponents", "NSURLComponents", "URLRequest", "NSMutableURLRequest",
    ]
    /// Operators whose result is still made of their operands: a default, a concatenation.
    private static let joining: Set<String> = ["??", "+"]

    /// What each binding of a function stands for, in source order — so a name bound to a name
    /// bound to a host is followed.
    static func names(of bindings: FunctionBindings, callee: Callee) -> HostNames {
        var names = HostNames()
        for site in bindings.sites where !site.isIteration {
            if let root = hostRoot(of: site.value, names: names) {
                names.hosts[site.name] = root
            } else if let from = derivedRoot(of: site.value) {
                names.derived[site.name] = from
            } else {
                let carried = carry(in: site.value, names: names, callee: callee)
                if !carried.isEmpty { names.carried[site.name] = carried }
            }
        }
        return names
    }

    /// The URL whose host `value` is — `url` for `url.host?.lowercased()`, for `raw ?? ""` where
    /// `raw` is bound to one, and for a name bound to either.
    static func hostRoot(of value: ExprSyntax, names: HostNames) -> String? {
        var current = RequestFlowCollector.unwrapped(value)
        for _ in 0..<8 {
            if let reference = current.as(DeclReferenceExprSyntax.self) {
                return names.hosts[reference.baseName.text]
            }
            if let sequence = current.as(SequenceExprSyntax.self) {
                // `host ?? ""`: the host, with a default.
                guard let first = operands(of: sequence, joinedBy: ["??"]).first else { return nil }
                current = RequestFlowCollector.unwrapped(first)
            } else if let call = current.as(FunctionCallExprSyntax.self),
                      let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base {
                if member.declName.baseName.text == "host" { return RequestFlowCollector.rootName(of: base) }
                guard RequestFlowCollector.hostTransforms.contains(member.declName.baseName.text) else { return nil }
                current = RequestFlowCollector.unwrapped(base)
            } else if let member = current.as(MemberAccessExprSyntax.self), let base = member.base {
                return member.declName.baseName.text == "host" ? RequestFlowCollector.rootName(of: base) : nil
            } else {
                return nil
            }
        }
        return nil
    }

    /// The URL a value was constructed to hold: `url` for `URLComponents(url: url, …)`.
    static func derivedRoot(of value: ExprSyntax) -> String? {
        guard let call = RequestFlowCollector.unwrapped(value).as(FunctionCallExprSyntax.self),
              let type = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
              holders.contains(type),
              let argument = call.arguments.first(where: { $0.label?.text == "url" }) else { return nil }
        return RequestFlowCollector.rootName(of: argument.expression)
    }

    /// The operands of an unfolded operator sequence, if every operator is one of `operators`.
    static func operands(of sequence: SequenceExprSyntax, joinedBy operators: Set<String>) -> [ExprSyntax] {
        var found: [ExprSyntax] = []
        for (index, element) in sequence.elements.enumerated() {
            if index % 2 == 1 {
                guard let symbol = element.as(BinaryOperatorExprSyntax.self)?.operator.text,
                      operators.contains(symbol) else { return [] }
            } else {
                found.append(element)
            }
        }
        return found
    }

    /// What `expression` carries: a host it is, a host given to the call or tuple or string it
    /// is, or a URL given whole to a call that may carry its host.
    ///
    /// A comparison carries nothing — `url.host != nil` is a `Bool` about the host, not the host.
    static func carry(in expression: ExprSyntax, names: HostNames, callee: Callee, depth: Int = 0) -> HostCarry {
        var found = HostCarry()
        // Bounded: each step descends into a part of the expression.
        guard depth < 6 else { return found }
        let value = RequestFlowCollector.unwrapped(expression)
        if let root = hostRoot(of: value, names: names) {
            found.roots = names.urls(of: root)
            return found
        }
        if let reference = value.as(DeclReferenceExprSyntax.self) {
            return names.carried[reference.baseName.text] ?? found
        }
        var parts: [ExprSyntax] = []
        if let tuple = value.as(TupleExprSyntax.self) {
            parts = tuple.elements.map(\.expression)
        } else if let literal = value.as(StringLiteralExprSyntax.self) {
            parts = literal.segments.compactMap { $0.as(ExpressionSegmentSyntax.self) }
                .flatMap { $0.expressions.map(\.expression) }
        } else if let sequence = value.as(SequenceExprSyntax.self) {
            parts = operands(of: sequence, joinedBy: joining)
        } else if let ternary = value.as(TernaryExprSyntax.self) {
            parts = [ternary.thenExpression, ternary.elseExpression]
        } else if let call = value.as(FunctionCallExprSyntax.self) {
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               RequestFlowCollector.comparisons.contains(member.declName.baseName.text) {
                return found
            }
            let name = callee(call)
            for (index, argument) in call.arguments.enumerated() {
                if let name, let whole = wholeName(argument.expression, names: names) {
                    for root in names.urls(of: whole) {
                        found.calls.append(.init(
                            root: root, slot: RequestSlot(function: name, label: argument.label?.text ?? "_\(index)")))
                    }
                } else {
                    parts.append(argument.expression)
                }
            }
        }
        for part in parts {
            found.merge(carry(in: part, names: names, callee: callee, depth: depth + 1))
        }
        return found
    }

    /// A bare name that is not already known to be a host or to hold one: a value handed over
    /// whole. (`url` in `Origin(url)` — which, bound to `URL(string: input)`, "carries" only the
    /// string it was parsed from, and is still the URL.)
    private static func wholeName(_ expression: ExprSyntax, names: HostNames) -> String? {
        guard let name = RequestFlowCollector.unwrapped(expression).as(DeclReferenceExprSyntax.self)?.baseName.text,
              names.hosts[name] == nil, names.carried[name]?.roots.isEmpty != false else { return nil }
        return name
    }
}

/// Reads ``HostFacts`` off a function body (§3.5, §12).
///
/// A **question** is the host compared with something that is not `nil`, tested for membership
/// or a prefix or suffix, switched on, or handed to a function inside a condition — and, since
/// §12, a *value made from the host* (an initialiser or tuple given it, a string it is
/// interpolated into, a name bound to any of those) that is compared or switched on. Asking
/// whether there *is* a host — `!= nil`, `isEmpty` — is not one, and neither is reading the host
/// to log it or binding it and never comparing it.
final class HostQuestionReader: SyntaxVisitor {
    private let names: HostNames
    private let body: SyntaxIdentifier
    private let calleeName: HostCarrying.Callee
    private(set) var questions: [HostFacts.Question] = []
    private(set) var checks: [HostFacts.Check] = []

    init(names: HostNames, body: SyntaxIdentifier, calleeName: @escaping HostCarrying.Callee) {
        self.names = names
        self.body = body
        self.calleeName = calleeName
        super.init(viewMode: .sourceAccurate)
    }

    // A nested function asks its own questions.
    private func enter(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        node.id == body ? .visitChildren : .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }

    private func ask(about root: String, at position: AbsolutePosition) {
        for url in names.urls(of: root) {
            questions.append(.init(root: url, position: position))
        }
    }

    private func check(_ root: String, by slot: RequestSlot, at position: AbsolutePosition, guards: Bool, compared: Bool) {
        for url in names.urls(of: root) {
            checks.append(.init(root: url, slot: slot, position: position, guards: guards, compared: compared))
        }
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.declName.baseName.text == "host", let base = node.base,
           let root = RequestFlowCollector.rootName(of: base), Self.isQuestion(about: Syntax(node)) {
            ask(about: root, at: node.position)
        }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if let root = names.hosts[name], Self.isQuestion(about: Syntax(node)) {
            ask(about: root, at: node.position)
        }
        // A value the host was carried into is a question only once it is compared.
        if let carried = names.carried[name], Self.isCompared(Syntax(node)) {
            for root in carried.roots {
                ask(about: root, at: node.position)
            }
            for call in carried.calls {
                check(call.root, by: call.slot, at: node.position, guards: false, compared: true)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let guards = Self.isInCondition(Syntax(node)) || Self.isTryStatement(Syntax(node))
        let compared = Self.isCompared(Syntax(node))
        guard guards || compared, let callee = calleeName(node) else { return .visitChildren }
        for (index, argument) in node.arguments.enumerated() {
            guard let root = RequestFlowCollector.unwrapped(argument.expression).as(DeclReferenceExprSyntax.self)?
                .baseName.text else { continue }
            check(
                root, by: RequestSlot(function: callee, label: argument.label?.text ?? "_\(index)"),
                at: node.position, guards: guards, compared: compared)
        }
        return .visitChildren
    }

    /// Whether the value at `node` — one a host was carried into — is compared with something:
    /// an operand of `==` / `!=` / `~=` against other than `nil`, a `switch` subject, or the
    /// argument or receiver of `contains` and its kin.
    static func isCompared(_ node: Syntax) -> Bool {
        isQuestion(about: node, carried: true)
    }

    /// Whether the host at `reference` is being asked about, rather than read or tested for presence.
    ///
    /// With `carried`, `reference` is a value made from the host rather than the host: being
    /// handed to a function in a condition is then not enough — it must be compared.
    static func isQuestion(about reference: Syntax, carried: Bool = false) -> Bool {
        var current = reference
        // Bounded climb through what leaves the value the host, or made of it: `?`, `!`, `()`,
        // `.lowercased()`, a tuple, a call it is an argument of, a string it is interpolated into.
        for _ in 0..<12 {
            guard let parent = current.parent else { return false }
            if parent.is(OptionalChainingExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self)
                || parent.is(PrefixOperatorExprSyntax.self) || parent.is(TryExprSyntax.self)
                || parent.is(AwaitExprSyntax.self) {
                current = parent
            } else if let member = parent.as(MemberAccessExprSyntax.self), member.base?.id == current.id {
                let name = member.declName.baseName.text
                if RequestFlowCollector.comparisons.contains(name) { return true }
                guard RequestFlowCollector.hostTransforms.contains(name) else { return false }
                current = parent
            } else if let call = parent.as(FunctionCallExprSyntax.self), call.calledExpression.id == current.id {
                current = parent
            } else if parent.is(ExprListSyntax.self), let sequence = parent.parent?.as(SequenceExprSyntax.self) {
                switch comparison(of: current, in: sequence) {
                case .compared: return true
                case .presence: return false
                case .coalesced: current = Syntax(sequence)
                case .other: return false
                }
            } else if let argument = parent.as(LabeledExprSyntax.self) {
                guard let list = argument.parent, let owner = list.parent else { return false }
                if owner.is(TupleExprSyntax.self) {
                    // `(url.host)`, and `(url.scheme, url.host, url.port)`: a value made of it.
                    current = owner
                } else if let call = owner.as(FunctionCallExprSyntax.self) {
                    let method = call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
                    if method.map(RequestFlowCollector.comparisons.contains) == true { return true }
                    if !carried, isInCondition(Syntax(call)) { return true }
                    // `Endpoint(host: url.host) == expected`: the call's result is what is asked about.
                    current = owner
                } else if owner.is(ExpressionSegmentSyntax.self),
                          let literal = owner.parent?.parent, literal.is(StringLiteralExprSyntax.self) {
                    // `"\(url.scheme)://\(url.host)" == expected`.
                    current = literal
                } else {
                    return false
                }
            } else if let switched = parent.as(SwitchExprSyntax.self) {
                return switched.subject.id == current.id
            } else {
                return false
            }
        }
        return false
    }

    private enum Comparison { case compared, presence, coalesced, other }
    private static let equalityOperators: Set<String> = ["==", "!=", "~="]

    /// How `operand` is used in an unfolded operator sequence.
    private static func comparison(of operand: Syntax, in sequence: SequenceExprSyntax) -> Comparison {
        let elements = Array(sequence.elements)
        guard let index = elements.firstIndex(where: { $0.id == operand.id }) else { return .other }
        var coalesced = false
        for (operatorIndex, otherIndex) in [(index - 1, index - 2), (index + 1, index + 2)]
        where elements.indices.contains(operatorIndex) && elements.indices.contains(otherIndex) {
            guard let symbol = elements[operatorIndex].as(BinaryOperatorExprSyntax.self)?.operator.text else { continue }
            if Self.equalityOperators.contains(symbol) {
                return elements[otherIndex].is(NilLiteralExprSyntax.self) ? .presence : .compared
            }
            if symbol == "??" { coalesced = true }
        }
        return coalesced ? .coalesced : .other
    }

    /// Whether `node` is inside a `guard` / `if` / `while` condition of its own function.
    static func isInCondition(_ node: Syntax) -> Bool {
        var cursor = node.parent
        while let current = cursor {
            if current.is(ConditionElementSyntax.self) { return true }
            if current.is(CodeBlockItemSyntax.self) || current.is(ClosureExprSyntax.self) { return false }
            cursor = current.parent
        }
        return false
    }

    /// `try validate(url)` as a statement: it throws instead of returning false.
    static func isTryStatement(_ node: Syntax) -> Bool {
        var cursor = node.parent
        var sawTry = false
        while let current = cursor {
            if current.is(TryExprSyntax.self) {
                sawTry = true
            } else if current.is(CodeBlockItemSyntax.self) {
                return sawTry
            } else if !current.is(AwaitExprSyntax.self) {
                return false
            }
            cursor = current.parent
        }
        return false
    }
}

// MARK: - Host carriers

/// Reads which URLs' hosts a function hands back in what it makes (§12.3): in a `return`, or —
/// in an initialiser — in what it assigns to the type's properties or passes to `self.init`.
///
/// `Origin.init(_ url: URL)` that stores `url.host` carries its parameter's host; so does
/// `func origin(of url: URL) -> String` that interpolates it. One that logs the host, or stores
/// only whether there is one, carries nothing.
final class HostCarrierReader: SyntaxVisitor {
    private let names: HostNames
    private let body: SyntaxIdentifier
    private let isInitializer: Bool
    private let calleeName: HostCarrying.Callee
    private let isProperty: (ExprSyntax) -> Bool
    private(set) var carried = HostCarry()

    init(names: HostNames, body: SyntaxIdentifier, isInitializer: Bool,
         calleeName: @escaping HostCarrying.Callee, isProperty: @escaping (ExprSyntax) -> Bool) {
        self.names = names
        self.body = body
        self.isInitializer = isInitializer
        self.calleeName = calleeName
        self.isProperty = isProperty
        super.init(viewMode: .sourceAccurate)
    }

    /// `expression` is part of what the function makes.
    func take(_ expression: ExprSyntax) {
        carried.merge(HostCarrying.carry(in: expression, names: names, callee: calleeName))
    }

    private func enter(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        node.id == body ? .visitChildren : .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    // A closure's `return` is the closure's, and what it assigns is not what the function made.
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if !isInitializer, let value = node.expression { take(value) }
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        // `self.host = url.host?.lowercased() ?? ""`, unfolded: [self.host, =, url.host…, ??, ""].
        let elements = Array(node.elements)
        guard isInitializer, elements.count >= 3, elements[1].is(AssignmentExprSyntax.self),
              isProperty(elements[0]) else { return .visitChildren }
        if elements.count == 3 {
            take(elements[2])
        } else {
            // What is assigned is a default or a concatenation of its operands — or, with any
            // other operator, something else: `present = url.host != nil` stores a `Bool`.
            var operands: [ExprSyntax] = []
            for (offset, element) in elements.dropFirst(2).enumerated() {
                if offset % 2 == 1 {
                    guard let symbol = element.as(BinaryOperatorExprSyntax.self)?.operator.text,
                          symbol == "??" || symbol == "+" else { return .visitChildren }
                } else {
                    operands.append(element)
                }
            }
            operands.forEach(take)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // `self.init(scheme: url.scheme, host: url.host)`: a delegating initialiser.
        if isInitializer, let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "init",
           member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
            take(ExprSyntax(node))
        }
        return .visitChildren
    }
}
