import Foundation
import SwiftSyntax

/// File-wide facts the main walk needs before it starts, so its answers do not depend on
/// whether a declaration comes above or below its use.
final class FilePrescan: SyntaxVisitor {
    /// Modules the file imports.
    private(set) var imports: Set<String> = []
    /// The file constructs a socket: `ServerBootstrap(`, `DatagramBootstrap(`, `NWListener(`,
    /// or calls `bind(host:…)`.
    private(set) var hasListenerConstruction = false
    /// The file constructs a `ServerBootstrap` or `DatagramBootstrap`.
    private(set) var hasBootstrap = false
    /// The file assigns `requiredLocalEndpoint` somewhere.
    private(set) var assignsLocalEndpoint = false
    /// Functions whose bodies call `req.auth.require(…)`, by name.
    private(set) var functionsRequiringAuth: Set<String> = []
    /// Names bound to an MCP server builder: `let builder = MCPServer.builder()`, or a parameter
    /// typed `MCPServerBuilder`.
    private(set) var builderNames: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let first = node.path.first { imports.insert(first.name.text) }
        return .skipChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let name = SyntaxReading.calleeName(node)
        if name == "ServerBootstrap" || name == "DatagramBootstrap" {
            hasBootstrap = true
            hasListenerConstruction = true
        }
        if name == "NWListener" { hasListenerConstruction = true }
        if name == "bind", SyntaxReading.argument(node, labelled: "host") != nil {
            hasListenerConstruction = true
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.declName.baseName.text == "requiredLocalEndpoint" { assignsLocalEndpoint = true }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body, SyntaxReading.requiresAuthentication(body) {
            functionsRequiringAuth.insert(node.name.text)
        }
        for parameter in node.signature.parameterClause.parameters
        where parameter.type.trimmedDescription == "MCPServerBuilder" {
            builderNames.insert(SyntaxReading.parameterName(parameter))
        }
        return .visitChildren
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
           let value = node.initializer?.value,
           value.trimmedDescription.contains("MCPServer.builder()") {
            builderNames.insert(name)
        }
        return .visitChildren
    }
}
