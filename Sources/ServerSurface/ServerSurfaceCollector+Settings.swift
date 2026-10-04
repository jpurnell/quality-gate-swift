import Foundation
import SwiftSyntax

/// Host and authentication settings: defaults, assignments, arguments, environment flags.
extension ServerSurfaceCollector {

    func addHostSetting(
        at node: some SyntaxProtocol, kind: HostSetting.Kind, name: String, value: String,
        addressKind: HostAddressKind, callee: String? = nil
    ) {
        facts.hostSettings.append(HostSetting(
            site: site(node), kind: kind, name: name, value: value, addressKind: addressKind,
            callee: callee, fileHasListener: prescan.hasListenerConstruction,
            owningType: SyntaxReading.enclosingTypeName(node)))
    }

    /// Records each chosen host literal in `expr` under `name`.
    ///
    /// Empty literals are skipped outside a bind: as a default for a `host` property an empty
    /// string more often means "unset" than "any". A literal that is neither all-interfaces nor
    /// loopback is recorded only when it is the whole expression, so a subscript key or a
    /// message fragment is not mistaken for an address.
    func recordHostLiterals(in expr: ExprSyntax, kind: HostSetting.Kind, name: String, callee: String? = nil) {
        let whole = expr.as(StringLiteralExprSyntax.self) != nil
        for literal in SyntaxReading.chosenLiterals(in: expr) {
            guard let value = literal.representedLiteralValue, !value.isEmpty else { continue }
            let addressKind = HostAddressKind.classify(value)
            guard addressKind != .specific || whole else { continue }
            addHostSetting(at: literal, kind: kind, name: name, value: value,
                           addressKind: addressKind, callee: callee)
        }
    }

    // MARK: - Parameters and bindings

    func recordParameterDefault(_ node: FunctionParameterSyntax) {
        guard let value = node.defaultValue?.value else { return }
        let name = SyntaxReading.parameterName(node)
        if ServerSurfaceVocabulary.hostNames.contains(name) {
            recordHostLiterals(in: value, kind: .parameterDefault, name: name)
        }
        if AuthReading.isOff(name: name, value: value.trimmedDescription) {
            facts.authSettings.append(AuthSetting(
                site: site(node), kind: .parameterDefault, names: [name],
                value: value.trimmedDescription, state: .off))
        }
    }

    func recordBinding(_ node: PatternBindingSyntax) {
        guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let value = node.initializer?.value else { return }
        if ServerSurfaceVocabulary.hostNames.contains(name) {
            recordHostLiterals(in: value, kind: .propertyDefault, name: name)
        }
        if AuthReading.isOff(name: name, value: value.trimmedDescription) {
            facts.authSettings.append(AuthSetting(
                site: site(node), kind: .propertyDefault, names: [name],
                value: value.trimmedDescription, state: .off))
        }
        recordEnvironmentFlag(name: name, value: value, at: node)
    }

    /// `authRequired = …environment["X"] != "false"`, as a binding or an assignment.
    func recordEnvironmentFlag(name: String, value: ExprSyntax, at node: some SyntaxProtocol) {
        guard let reading = AuthReading.environmentFlag(name: name, value: value) else { return }
        facts.authSettings.append(AuthSetting(
            site: site(node), kind: .environmentFlag, names: [name],
            value: value.trimmedDescription, state: reading.state, environmentKey: reading.key))
    }

    // MARK: - Assignments

    func recordAssignment(_ node: SequenceExprSyntax) {
        let elements = Array(node.elements)
        guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self) else { return }
        let lhs = elements[0]
        let rhs = elements[2]
        recordSocketAddressAssignment(lhs: lhs, rhs: rhs)
        let member = lhs.as(MemberAccessExprSyntax.self)?.declName.baseName.text
            ?? lhs.as(DeclReferenceExprSyntax.self)?.baseName.text
        guard let member else { return }
        if member == "hostname" || member == "host", lhs.is(MemberAccessExprSyntax.self) {
            recordHostLiterals(in: rhs, kind: .assignment, name: member)
            if lhs.trimmedDescription.hasSuffix("http.server.configuration.hostname") {
                facts.vaporHostnames.append((binding: hostBinding(rhs), site: site(node)))
            }
        }
        recordEnvironmentFlag(name: member, value: rhs, at: node)
    }

    // MARK: - Arguments

    /// `TournamentWebSocketServer(host: "0.0.0.0", …)`, `WebOptions(bindAddress: …)`.
    func recordHostArguments(_ node: FunctionCallExprSyntax) {
        guard let callee = SyntaxReading.calleeName(node),
              !ServerSurfaceVocabulary.clientCallees.contains(callee) else { return }
        for argument in node.arguments {
            guard let label = argument.label?.text,
                  ServerSurfaceVocabulary.hostArgumentLabels.contains(label) else { continue }
            recordHostLiterals(in: argument.expression, kind: .argument, name: label, callee: callee)
        }
    }

    /// An authenticator passed as `nil`/`.none`. Kept by the assembly only when the callee is a
    /// listener type — a client's `authenticator: nil` is its own business.
    func recordAuthArguments(_ node: FunctionCallExprSyntax) {
        guard let callee = SyntaxReading.calleeName(node) else { return }
        var names: [String] = []
        var values: [String] = []
        for argument in node.arguments {
            guard let label = argument.label?.text,
                  AuthReading.isOff(name: label, value: argument.expression.trimmedDescription) else { continue }
            names.append(label)
            values.append(argument.expression.trimmedDescription)
        }
        guard !names.isEmpty else { return }
        facts.authSettings.append(AuthSetting(
            site: site(node), kind: .argument, names: names,
            value: values.joined(separator: ", "), state: .off, callee: callee))
    }
}

/// Every off-valued authentication argument under a node, nested calls included.
final class AuthArgumentFinder: SyntaxVisitor {
    private(set) var offNames: [String] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: LabeledExprSyntax) -> SyntaxVisitorContinueKind {
        if let label = node.label?.text,
           AuthReading.isOff(name: label, value: node.expression.trimmedDescription) {
            offNames.append(label)
        }
        return .visitChildren
    }
}

/// How an authentication name and its value are read.
enum AuthReading {

    /// Whether `value` turns off the authentication `name` stands for.
    static func isOff(name: String, value: String) -> Bool {
        if ServerSurfaceVocabulary.authenticatorNames.contains(name) {
            return value == "nil" || value == ".none"
        }
        if ServerSurfaceVocabulary.modeNames.contains(name) {
            return ServerSurfaceVocabulary.offModes.contains(value)
        }
        if ServerSurfaceVocabulary.onFlagNames.contains(name) { return value == "false" }
        if ServerSurfaceVocabulary.offFlagNames.contains(name) { return value == "true" }
        return false
    }

    /// A flag whose value comes from the process environment, and what it is when unset.
    static func environmentFlag(name: String, value: ExprSyntax) -> (key: String?, state: AuthSetting.State)? {
        let isOnFlag = ServerSurfaceVocabulary.onFlagNames.contains(name)
        guard isOnFlag || ServerSurfaceVocabulary.offFlagNames.contains(name) else { return nil }
        let text = value.trimmedDescription
        guard text.contains("environment[") || text.contains("getenv(") || text.contains("Environment.get(") else {
            return nil
        }
        let key = firstSubscriptKey(in: value)
        // Unset reads as nil; `!= "false"` is then true and `== "true"` is false.
        let unsetIsTrue = text.contains("!=") || text.contains("?? true") || text.contains("?? \"true\"")
        let authOnWhenUnset = isOnFlag ? unsetIsTrue : !unsetIsTrue
        return (key, authOnWhenUnset ? .onUnlessDisabled : .offUnlessSet)
    }

    /// The literal key of the first subscript or call argument under `value`.
    private static func firstSubscriptKey(in value: ExprSyntax) -> String? {
        let finder = KeyFinder()
        finder.walk(value)
        return finder.key
    }
}

/// The first string literal under a node, wherever it sits.
private final class KeyFinder: SyntaxVisitor {
    var key: String?

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        if key == nil { key = node.representedLiteralValue }
        return .skipChildren
    }
}
