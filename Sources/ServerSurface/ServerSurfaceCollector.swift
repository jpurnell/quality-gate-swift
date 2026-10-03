import Foundation
import SwiftSyntax

/// Walks one file and records its listeners, handlers and settings.
///
/// Split by subject across extensions: listeners here, settings in `+Settings`, Vapor routes in
/// `+Vapor`, SwiftMCPServer and hand-written NIO in `+Handlers`.
final class ServerSurfaceCollector: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let prescan: FilePrescan
    var facts: ServerSurfaceFileFacts

    init(fileName: String, converter: SourceLocationConverter, prescan: FilePrescan) {
        self.fileName = fileName
        self.converter = converter
        self.prescan = prescan
        self.facts = ServerSurfaceFileFacts(fileName: fileName)
        super.init(viewMode: .sourceAccurate)
    }

    /// Where `node` starts, past its leading trivia.
    func site(_ node: some SyntaxProtocol) -> SourceSite {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return SourceSite(file: fileName, line: location.line, column: location.column)
    }

    var importsVapor: Bool { prescan.imports.contains("Vapor") }

    // MARK: - Dispatch

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        recordListener(node)
        recordHostArguments(node)
        recordAuthArguments(node)
        if importsVapor { recordVaporCall(node) }
        recordMCPCall(node)
        recordNIOCall(node)
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        recordParameterDefault(node)
        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        recordBinding(node)
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        recordAssignment(node)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        recordTypeDeclaration(name: node.name, inheritance: node.inheritanceClause, members: node.memberBlock)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        recordTypeDeclaration(name: node.name, inheritance: node.inheritanceClause, members: node.memberBlock)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        recordTypeDeclaration(name: node.name, inheritance: node.inheritanceClause, members: node.memberBlock)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        facts.declaredTypes.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        recordChannelRead(node)
        return .visitChildren
    }

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        recordDispatchSwitch(node)
        return .visitChildren
    }

    // MARK: - Listeners

    /// Records a socket opened by `node`, if it opens one.
    private func recordListener(_ node: FunctionCallExprSyntax) {
        guard let name = SyntaxReading.calleeName(node) else { return }
        switch name {
        case "bind": recordBind(node)
        case "NWListener": recordNWListener(node)
        case "make", "Application": recordVaporApplication(node, name: name)
        case "builder": recordMCPBuilder(node)
        case "hostPort": recordLocalEndpoint(node)
        default:
            if ServerSurfaceVocabulary.knownListenerTypes[name] != nil,
               node.calledExpression.is(DeclReferenceExprSyntax.self) {
                recordKnownListener(node, type: name)
            }
        }
    }

    private func addListener(_ node: some SyntaxProtocol, framework: ServerFramework,
                             construct: String, host: HostBinding, port: String? = nil) {
        let owner = SyntaxReading.enclosingTypeName(node)
        facts.listeners.append(ServerListener(
            site: site(node), framework: framework, construct: construct, host: host,
            port: port, owningType: owner))
        if let owner, framework == .nio || framework == .network {
            facts.listenerOwningTypes.insert(owner)
        }
    }

    /// `bootstrap.bind(host:port:)`, `bind(to:)` and `bind(unixDomainSocketPath:)`.
    private func recordBind(_ node: FunctionCallExprSyntax) {
        let port = SyntaxReading.argument(node, labelled: "port")?.trimmedDescription
        if let hostExpr = SyntaxReading.argument(node, labelled: "host") {
            let host = hostBinding(hostExpr)
            addListener(node, framework: .nio, construct: bindConstruct(node), host: host, port: port)
            if case .literal(let value, let kind) = host {
                addHostSetting(at: hostExpr, kind: .bindArgument, name: "host", value: value,
                               addressKind: kind, callee: "bind")
            }
            return
        }
        guard prescan.hasBootstrap else { return }
        if SyntaxReading.argument(node, labelled: "unixDomainSocketPath") != nil {
            addListener(node, framework: .nio, construct: bindConstruct(node), host: .unixSocket)
        } else if SyntaxReading.argument(node, labelled: "to") != nil {
            addListener(node, framework: .nio, construct: bindConstruct(node), host: .unknown)
        }
    }

    private func bindConstruct(_ node: FunctionCallExprSyntax) -> String {
        let receiverText = SyntaxReading.receiver(node)?.trimmedDescription ?? ""
        if receiverText.contains("DatagramBootstrap") { return "DatagramBootstrap.bind" }
        return prescan.hasBootstrap ? "ServerBootstrap.bind" : "bind"
    }

    /// A host expression: a literal decides; anything else is the caller's, resolved later
    /// against the owning type's defaults.
    func hostBinding(_ expr: ExprSyntax) -> HostBinding {
        if let value = SyntaxReading.stringValue(expr) {
            return .literal(value, HostAddressKind.classify(value))
        }
        return .expression(expr.trimmedDescription, defaultValue: nil)
    }

    /// `NWListener(using:)`: the address is the `requiredLocalEndpoint` set in the same body.
    private func recordNWListener(_ node: FunctionCallExprSyntax) {
        let body = SyntaxReading.enclosingBody(node)
        let finder = LocalEndpointFinder()
        finder.walk(body)
        let host: HostBinding
        if let endpoint = finder.endpoint {
            host = endpointBinding(endpoint)
        } else if prescan.assignsLocalEndpoint {
            host = .unknown
        } else {
            host = .frameworkDefault(.allInterfaces, note: ServerSurfaceVocabulary.nwListenerDefaultNote)
        }
        let port = SyntaxReading.argument(node, labelled: "on")?.trimmedDescription
        addListener(node, framework: .network, construct: "NWListener", host: host, port: port)
    }

    private func endpointBinding(_ endpoint: ExprSyntax) -> HostBinding {
        let text = endpoint.trimmedDescription
        if text.contains(".unix(") || text.hasPrefix("NWEndpoint.unix") { return .unixSocket }
        guard let call = endpoint.as(FunctionCallExprSyntax.self),
              SyntaxReading.calleeName(call) == "hostPort",
              let hostExpr = SyntaxReading.argument(call, labelled: "host") else {
            return .unknown
        }
        return hostBinding(hostExpr)
    }

    /// `.hostPort(host: "::", …)` assigned to `requiredLocalEndpoint` is a bind address; the
    /// same endpoint handed to `NWConnection` is a destination, and is not.
    private func recordLocalEndpoint(_ node: FunctionCallExprSyntax) {
        guard let hostExpr = SyntaxReading.argument(node, labelled: "host"),
              let value = SyntaxReading.stringValue(hostExpr),
              let assignment = node.parent?.as(ExprListSyntax.self)?.parent?.as(SequenceExprSyntax.self),
              let lhs = assignment.elements.first?.as(MemberAccessExprSyntax.self),
              lhs.declName.baseName.text == "requiredLocalEndpoint" else { return }
        addHostSetting(at: hostExpr, kind: .bindArgument, name: "host", value: value,
                       addressKind: HostAddressKind.classify(value), callee: "hostPort")
    }

    /// `Application.make(…)` or `Application(…)` in a file importing Vapor.
    private func recordVaporApplication(_ node: FunctionCallExprSyntax, name: String) {
        guard importsVapor else { return }
        if name == "make" {
            guard SyntaxReading.receiver(node)?.trimmedDescription == "Application" else { return }
        } else if !node.calledExpression.is(DeclReferenceExprSyntax.self) {
            return
        }
        addListener(node, framework: .vapor, construct: name == "make" ? "Application.make" : "Application",
                    host: .frameworkDefault(.loopback, note: ServerSurfaceVocabulary.vaporDefaultNote))
    }

    /// `MCPServer.builder()` — the listener is inside the library.
    private func recordMCPBuilder(_ node: FunctionCallExprSyntax) {
        guard SyntaxReading.receiver(node)?.trimmedDescription == "MCPServer" else { return }
        addListener(node, framework: .swiftMCPServer, construct: "MCPServer.builder",
                    host: .inherited(library: "SwiftMCPServer", kind: .allInterfaces,
                                     note: ServerSurfaceVocabulary.mcpBuilderNote))
    }

    /// `HTTPServerTransport(…)`, `SSHServer(…)` — a library listener constructed here.
    private func recordKnownListener(_ node: FunctionCallExprSyntax, type: String) {
        let host: HostBinding
        if let hostExpr = SyntaxReading.argument(node, labelled: "host") {
            host = hostBinding(hostExpr)
        } else {
            host = .inherited(library: ServerSurfaceVocabulary.knownListenerTypes[type] ?? type,
                              kind: .allInterfaces,
                              note: ServerSurfaceVocabulary.knownListenerNotes[type] ?? "")
        }
        let framework: ServerFramework = type == "HTTPServerTransport" ? .swiftMCPServer : .nio
        addListener(node, framework: framework, construct: type, host: host,
                    port: SyntaxReading.argument(node, labelled: "port")?.trimmedDescription)
        let finder = AuthArgumentFinder()
        finder.walk(node.arguments)
        facts.knownListenerAuthOff.append((site: site(node), type: type, names: finder.offNames))
    }

    private func recordTypeDeclaration(
        name: TokenSyntax, inheritance: InheritanceClauseSyntax?, members: MemberBlockSyntax
    ) {
        facts.declaredTypes.insert(name.text)
        recordMCPConformance(name: name, inheritance: inheritance, members: members)
    }
}

/// The last `requiredLocalEndpoint = …` in a body.
final class LocalEndpointFinder: SyntaxVisitor {
    private(set) var endpoint: ExprSyntax?

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard elements.count == 3, elements[1].is(AssignmentExprSyntax.self),
              let lhs = elements[0].as(MemberAccessExprSyntax.self),
              lhs.declName.baseName.text == "requiredLocalEndpoint" else {
            return .visitChildren
        }
        endpoint = elements[2]
        return .skipChildren
    }
}
