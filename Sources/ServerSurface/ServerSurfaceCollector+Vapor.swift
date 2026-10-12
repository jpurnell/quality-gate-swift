import Foundation
import SwiftSyntax

/// Where a routes-shaped receiver came from, and what stands between it and the application.
struct RouteContext {
    /// The application, or the `RoutesBuilder` a collection's `boot(routes:)` was handed.
    enum Root: Equatable {
        case application
        case collection(String)
    }

    var root: Root
    var prefix: [String] = []
    var lineage: [String] = []

    /// This context with a `grouped(…)` / `group(…)` call's arguments added.
    func adding(_ arguments: LabeledExprListSyntax) -> RouteContext {
        var next = self
        for argument in arguments where !argument.expression.is(ClosureExprSyntax.self) {
            if let value = SyntaxReading.stringValue(argument.expression) {
                next.prefix.append(value)
            } else {
                next.lineage.append(argument.expression.trimmedDescription)
            }
        }
        return next
    }
}

/// Vapor: route registrations, group lineage, collections and application middleware.
extension ServerSurfaceCollector {

    func recordVaporCall(_ node: FunctionCallExprSyntax) {
        guard let name = SyntaxReading.calleeName(node), let receiver = SyntaxReading.receiver(node) else { return }
        if ServerSurfaceVocabulary.routeMethods.contains(name), hasHandlerBody(node),
           let context = routeContext(of: receiver, depth: 0) {
            addRoute(node, method: name, context: context)
        } else if name == "register", let collection = SyntaxReading.argument(node, labelled: "collection"),
                  let context = routeContext(of: receiver, depth: 0) {
            addRegistration(node, collection: collection, context: context)
        } else if name == "use", let member = receiver.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "middleware", let base = member.base,
                  routeContext(of: base, depth: 0) != nil, let first = node.arguments.first {
            facts.applicationMiddleware.append(first.expression.trimmedDescription)
        }
    }

    private func hasHandlerBody(_ node: FunctionCallExprSyntax) -> Bool {
        node.trailingClosure != nil
            || SyntaxReading.argument(node, labelled: "use") != nil
            || node.arguments.last?.expression.is(ClosureExprSyntax.self) == true
    }

    private func addRoute(_ node: FunctionCallExprSyntax, method name: String, context: RouteContext) {
        var arguments = Array(node.arguments.filter { $0.label == nil && !$0.expression.is(ClosureExprSyntax.self) })
        var method = name == "webSocket" ? "GET" : name.uppercased()
        if name == "on", let first = arguments.first {
            method = first.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text.uppercased()
                ?? ServerHandler.dynamicRoute
            arguments.removeFirst()
        }
        let components = arguments.map { SyntaxReading.stringValue($0.expression) ?? ServerHandler.dynamicRoute }
        let row = ServerHandler(site: site(node), framework: .vapor, kind: .route, method: method, route: "")
        var pending = PendingHandler(row: row)
        pending.prefix = context.prefix
        pending.components = components
        pending.lineage = context.lineage
        pending.requiresInHandler = handlerRequiresAuthentication(node)
        if case .collection(let type) = context.root { pending.collection = type }
        facts.handlers.append(pending)
    }

    private func handlerRequiresAuthentication(_ node: FunctionCallExprSyntax) -> Bool {
        if let closure = node.trailingClosure, SyntaxReading.requiresAuthentication(closure) { return true }
        guard let use = SyntaxReading.argument(node, labelled: "use") else {
            return node.arguments.last.map { SyntaxReading.requiresAuthentication($0.expression) } ?? false
        }
        if let reference = use.as(DeclReferenceExprSyntax.self) {
            return prescan.functionsRequiringAuth.contains(reference.baseName.text)
        }
        return SyntaxReading.requiresAuthentication(use)
    }

    private func addRegistration(_ node: FunctionCallExprSyntax, collection: ExprSyntax, context: RouteContext) {
        let unwrapped = SyntaxReading.unwrapped(collection)
        let typeName = unwrapped.as(FunctionCallExprSyntax.self).flatMap(SyntaxReading.calleeName)
            ?? unwrapped.trimmedDescription
        facts.registrations.append(CollectionRegistration(
            typeName: typeName, prefix: context.prefix, lineage: context.lineage, site: site(node),
            root: context.root))
    }

    // MARK: - Resolving a receiver

    /// What a receiver expression is, if it is routes-shaped.
    ///
    /// Recursive through `grouped(…)` chains and the bindings and closure parameters a name
    /// refers to; `depth` is the base case, so a binding that refers to itself ends.
    func routeContext(of expression: ExprSyntax, depth: Int) -> RouteContext? {
        guard depth < 12 else { return nil }
        let expr = SyntaxReading.unwrapped(expression)
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return routeContext(ofCall: call, depth: depth + 1)
        }
        if let member = expr.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "routes",
           let base = member.base {
            return routeContext(of: base, depth: depth + 1)
        }
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return routeContext(ofName: reference.baseName.text, at: Syntax(reference), depth: depth + 1)
        }
        return nil
    }

    private func routeContext(ofCall call: FunctionCallExprSyntax, depth: Int) -> RouteContext? {
        let name = SyntaxReading.calleeName(call)
        if name == "grouped", let receiver = SyntaxReading.receiver(call) {
            return routeContext(of: receiver, depth: depth)?.adding(call.arguments)
        }
        let receiverText = SyntaxReading.receiver(call)?.trimmedDescription
        if (name == "make" && receiverText == "Application")
            || (name == "Application" && call.calledExpression.is(DeclReferenceExprSyntax.self)) {
            return RouteContext(root: .application)
        }
        return nil
    }

    /// What `name` is bound to at `node`: the nearest binding before it, a closure parameter of a
    /// `group(…)` call, or a routes-typed function parameter.
    private func routeContext(ofName name: String, at node: Syntax, depth: Int) -> RouteContext? {
        var current = node.parent
        while let ancestor = current {
            if let list = ancestor.as(CodeBlockItemListSyntax.self),
               let value = latestBinding(named: name, in: list, before: node.position) {
                return routeContext(of: value, depth: depth)
            }
            if let closure = ancestor.as(ClosureExprSyntax.self), closureParameters(closure).contains(name) {
                return groupClosureContext(closure, depth: depth)
            }
            if let function = ancestor.as(FunctionDeclSyntax.self) {
                return parameterContext(name: name, in: function)
            }
            current = ancestor.parent
        }
        return nil
    }

    private func latestBinding(named name: String, in list: CodeBlockItemListSyntax, before position: AbsolutePosition) -> ExprSyntax? {
        var found: ExprSyntax?
        for item in list where item.position < position {
            guard let variable = item.item.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings
            where binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name {
                found = binding.initializer?.value ?? found
            }
        }
        return found
    }

    private func closureParameters(_ closure: ClosureExprSyntax) -> [String] {
        switch closure.signature?.parameterClause {
        case .simpleInput(let shorthand): return shorthand.map(\.name.text)
        case .parameterClause(let clause): return clause.parameters.map { ($0.secondName ?? $0.firstName).text }
        case nil: return []
        }
    }

    /// The context a `group(…) { r in … }` closure's parameter carries.
    private func groupClosureContext(_ closure: ClosureExprSyntax, depth: Int) -> RouteContext? {
        var parent = closure.parent
        if parent?.is(LabeledExprSyntax.self) == true { parent = parent?.parent?.parent }
        guard let call = parent?.as(FunctionCallExprSyntax.self), SyntaxReading.calleeName(call) == "group",
              let receiver = SyntaxReading.receiver(call) else { return nil }
        return routeContext(of: receiver, depth: depth)?.adding(call.arguments)
    }

    private func parameterContext(name: String, in function: FunctionDeclSyntax) -> RouteContext? {
        let parameters = function.signature.parameterClause.parameters
        guard let parameter = parameters.first(where: { SyntaxReading.parameterName($0) == name }),
              ServerSurfaceVocabulary.routesTypes.contains(parameter.type.trimmedDescription) else { return nil }
        if function.name.text == "boot", let owner = SyntaxReading.enclosingTypeName(function) {
            return RouteContext(root: .collection(owner))
        }
        return RouteContext(root: .application)
    }
}
