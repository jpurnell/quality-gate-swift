import Foundation
import SwiftSyntax

/// SwiftMCPServer and the MCP SDK; hand-written NIO dispatch, channel handlers, WebSockets.
extension ServerSurfaceCollector {

    // MARK: - SwiftMCPServer

    /// An `MCPToolHandler`, `MCPResourceProvider` or `MCPPromptProvider` conformer is a row.
    func recordMCPConformance(name: TokenSyntax, inheritance: InheritanceClauseSyntax?, members: MemberBlockSyntax) {
        let conformances = Set(inheritance?.inheritedTypes.map(\.type.trimmedDescription) ?? [])
        if conformances.contains("MCPToolHandler") {
            addRow(name, framework: .swiftMCPServer, kind: .mcpTool, method: "tools/call",
                   route: toolName(in: members) ?? ServerHandler.dynamicRoute)
        }
        if conformances.contains("MCPResourceProvider") {
            addRow(name, framework: .swiftMCPServer, kind: .mcpProvider, method: "resources/read", route: name.text)
        }
        if conformances.contains("MCPPromptProvider") {
            addRow(name, framework: .swiftMCPServer, kind: .mcpProvider, method: "prompts/get", route: name.text)
        }
    }

    private func addRow(
        _ node: some SyntaxProtocol, framework: ServerFramework, kind: HandlerKind, method: String?,
        route: String, auth: HandlerAuth = HandlerAuth()
    ) {
        facts.handlers.append(PendingHandler(row: ServerHandler(
            site: site(node), framework: framework, kind: kind, method: method, route: route, auth: auth)))
    }

    /// The literal `name:` of the `MCPTool(…)` a tool handler declares.
    private func toolName(in members: MemberBlockSyntax) -> String? {
        let finder = CallFinder(callee: "MCPTool")
        finder.walk(members)
        return finder.calls.lazy.compactMap { SyntaxReading.stringValue(SyntaxReading.argument($0, labelled: "name")) }.first
    }

    /// `MCPHTTPRoute(…)`, `withMethodHandler(T.self)`, and what a builder is told about its
    /// address and its authentication: `.listen(host:)`, `.authenticator(…)`, `.oauthServer(…)`,
    /// `.authentication(…)`.
    func recordMCPCall(_ node: FunctionCallExprSyntax) {
        guard let name = SyntaxReading.calleeName(node) else { return }
        switch name {
        case "MCPHTTPRoute":
            let path = SyntaxReading.argument(node, labelled: "pathPrefix") ?? SyntaxReading.argument(node, labelled: "path")
            let declared = SyntaxReading.argument(node, labelled: "requiresAuthentication")?
                .as(BooleanLiteralExprSyntax.self).map { $0.literal.tokenKind == .keyword(.true) }
            addRow(node, framework: .swiftMCPServer, kind: .mcpHTTPRoute, method: nil,
                   route: SyntaxReading.stringValue(path) ?? ServerHandler.dynamicRoute,
                   auth: HandlerAuth(declaredRequiresAuthentication: declared))
        case "withMethodHandler":
            let type = node.arguments.first?.expression.trimmedDescription
                .replacingOccurrences(of: ".self", with: "") ?? ServerHandler.dynamicRoute
            addRow(node, framework: .mcpSDK, kind: .mcpMethodHandler, method: nil, route: type)
        case "authenticator", "oauthServer":
            if let receiver = SyntaxReading.receiver(node), isBuilder(receiver) {
                facts.mcpTransportAuth.append(name)
                facts.mcpBuilderAuth.append((site: memberSite(node), name: name, enforced: true))
            }
        case "authentication":
            recordBuilderAuthentication(node)
        case "listen":
            recordBuilderListen(node)
        default:
            break
        }
    }

    /// Where the method name of a chained call is written: the `.authentication` of a builder
    /// chain, not the `MCPServer` the chain starts at — a finding belongs on the line that made
    /// the choice, which is also the line an acknowledgement is written above.
    private func memberSite(_ node: FunctionCallExprSyntax) -> SourceSite {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return site(node) }
        return site(member.period)
    }

    /// `.authentication(…)` on a builder — SwiftMCPServer 5's one way to say, in code, what the
    /// transport enforces, and its only way to ask for nothing.
    private func recordBuilderAuthentication(_ node: FunctionCallExprSyntax) {
        guard let receiver = SyntaxReading.receiver(node), isBuilder(receiver),
              let chosen = node.arguments.first, chosen.label == nil else { return }
        facts.mcpReleaseShapes.insert(LibraryRelease.swiftMCPServerLoopbackMajor)
        let value = chosen.expression.trimmedDescription
        let written = memberSite(node)
        if AuthReading.isOff(name: "authentication", value: value) {
            facts.mcpBuilderAuth.append((site: written, name: "authentication", enforced: false))
            facts.authSettings.append(AuthSetting(
                site: written, kind: .argument, names: ["authentication"], value: value, state: .off,
                callee: ServerSurfaceVocabulary.mcpBuilderType))
        } else if let enforcing = AuthReading.enforcingCase(chosen.expression) {
            facts.mcpTransportAuth.append("authentication")
            facts.mcpBuilderAuth.append((site: written, name: enforcing, enforced: true))
        }
    }

    /// `.listen(host:)` on a builder: the address the server binds unless `--host` overrides it.
    private func recordBuilderListen(_ node: FunctionCallExprSyntax) {
        guard let receiver = SyntaxReading.receiver(node), isBuilder(receiver),
              let host = SyntaxReading.argument(node, labelled: "host") else { return }
        facts.mcpReleaseShapes.insert(LibraryRelease.swiftMCPServerLoopbackMajor)
        facts.mcpListenHosts.append((binding: hostBinding(host), site: memberSite(node)))
    }

    /// Whether `expr` is an MCP server builder: a chain from `MCPServer.builder()`, or a name
    /// bound to one.
    func isBuilder(_ expr: ExprSyntax) -> Bool {
        if expr.trimmedDescription.contains("MCPServer.builder()") { return true }
        var root = expr
        while let next = Self.chainBase(root) { root = next }
        guard let reference = root.as(DeclReferenceExprSyntax.self) else { return false }
        return prescan.builderNames.contains(reference.baseName.text)
    }

    /// One step toward the root of a call chain.
    private static func chainBase(_ expr: ExprSyntax) -> ExprSyntax? {
        if let call = expr.as(FunctionCallExprSyntax.self) { return call.calledExpression }
        if let member = expr.as(MemberAccessExprSyntax.self) { return member.base }
        return nil
    }

    // MARK: - Hand-written NIO

    /// `switch (method, path) { case (.GET, "/health"): … }` in a file importing NIOHTTP1.
    func recordDispatchSwitch(_ node: SwitchExprSyntax) {
        guard prescan.imports.contains("NIOHTTP1"),
              let subject = node.subject.as(TupleExprSyntax.self), subject.elements.count == 2 else { return }
        for case .switchCase(let switchCase) in node.cases {
            guard let label = switchCase.label.as(SwitchCaseLabelSyntax.self) else { continue }
            for item in label.caseItems {
                guard let route = Self.dispatchRoute(item.pattern) else { continue }
                addRow(switchCase, framework: .nio, kind: .dispatchCase, method: route.method, route: route.path)
            }
        }
    }

    /// `(.GET, "/health")` as a method and a path.
    private static func dispatchRoute(_ pattern: PatternSyntax) -> (method: String, path: String)? {
        guard let tuple = pattern.as(ExpressionPatternSyntax.self)?.expression.as(TupleExprSyntax.self),
              tuple.elements.count == 2 else { return nil }
        let elements = Array(tuple.elements)
        guard let method = elements[0].expression.as(MemberAccessExprSyntax.self), method.base == nil,
              let path = SyntaxReading.stringValue(elements[1].expression) else { return nil }
        return (method.declName.baseName.text.uppercased(), path)
    }

    /// `func channelRead(context:data:)` — a row only if a server bootstrap installs its type.
    func recordChannelRead(_ node: FunctionDeclSyntax) {
        guard node.name.text == "channelRead",
              node.signature.parameterClause.parameters.first?.firstName.text == "context",
              let owner = SyntaxReading.enclosingTypeName(node) else { return }
        facts.channelReads.append((type: owner, site: site(node.name)))
    }

    /// Handler types installed by `childChannelInitializer` or a WebSocket upgrade, and the
    /// upgrade itself.
    func recordNIOCall(_ node: FunctionCallExprSyntax) {
        let name = SyntaxReading.calleeName(node)
        if name == "childChannelInitializer" {
            facts.serverHandlerTypes.formUnion(Self.constructedTypes(in: node.arguments, trailing: node.trailingClosure))
        }
        if let initializer = SyntaxReading.argument(node, labelled: "childChannelInitializer") {
            facts.serverHandlerTypes.formUnion(Self.constructedTypes(in: initializer))
        }
        guard name == "NIOWebSocketServerUpgrader" else { return }
        let pipeline = SyntaxReading.argument(node, labelled: "upgradePipelineHandler")
        let installed = pipeline.map(Self.constructedTypes(in:)) ?? []
        facts.serverHandlerTypes.formUnion(installed)
        addRow(node, framework: .nio, kind: .webSocketUpgrade, method: "GET",
               route: installed.first ?? ServerHandler.dynamicRoute)
    }

    private static func constructedTypes(in arguments: LabeledExprListSyntax, trailing: ClosureExprSyntax?) -> [String] {
        var types = arguments.flatMap { constructedTypes(in: $0.expression) }
        if let trailing { types += constructedTypes(in: ExprSyntax(trailing)) }
        return types
    }

    /// Capitalised type names constructed under `expr`, in source order.
    static func constructedTypes(in expr: ExprSyntax) -> [String] {
        let finder = CallFinder(callee: nil)
        finder.walk(expr)
        return finder.calls.compactMap { call in
            guard let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
                  reference.baseName.text.first?.isUppercase == true else { return nil }
            return reference.baseName.text
        }
    }
}

/// Calls under a node, optionally only those to one callee.
final class CallFinder: SyntaxVisitor {
    private let callee: String?
    private(set) var calls: [FunctionCallExprSyntax] = []

    init(callee: String?) {
        self.callee = callee
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if callee == nil || SyntaxReading.calleeName(node) == callee { calls.append(node) }
        return .visitChildren
    }
}
