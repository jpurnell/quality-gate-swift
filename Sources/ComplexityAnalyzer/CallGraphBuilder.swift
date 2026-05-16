import SwiftSyntax
import SwiftParser

/// Builds an intra-module call graph from Swift source code.
///
/// Walks the AST to find all function declarations and the calls between them.
/// Only tracks calls to functions defined within the same source unit.
struct CallGraphBuilder {

    /// Builds a call graph from a Swift source string.
    static func build(source: String, moduleName: String) -> CallGraph {
        let tree = Parser.parse(source: source)
        let collector = FunctionCollector(viewMode: .sourceAccurate)
        collector.walk(tree)

        let definedNames = Set(collector.functions.map(\.name))
        var edges: [CallEdge] = []

        for function in collector.functions {
            guard let body = function.body else { continue }
            let callFinder = CallFinder(
                callerName: function.name,
                definedFunctions: definedNames,
                tree: tree
            )
            callFinder.walk(body)
            edges.append(contentsOf: callFinder.edges)
        }

        return CallGraph(edges: edges, definedFunctions: definedNames)
    }
}

/// Collects top-level function declarations from a source file.
private final class FunctionCollector: SyntaxVisitor {
    struct FunctionInfo {
        let name: String
        let body: CodeBlockSyntax?
    }

    var functions: [FunctionInfo] = []

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        functions.append(FunctionInfo(name: name, body: node.body))
        return .skipChildren
    }
}

/// Finds calls to known functions within a function body.
private final class CallFinder: SyntaxVisitor {
    let callerName: String
    let definedFunctions: Set<String>
    let tree: SyntaxProtocol
    var edges: [CallEdge] = []
    private var loopDepth: Int = 0

    init(callerName: String, definedFunctions: Set<String>, tree: SyntaxProtocol) {
        self.callerName = callerName
        self.definedFunctions = definedFunctions
        self.tree = tree
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Loop tracking

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        loopDepth += 1
        for statement in node.body.statements { walk(statement) }
        loopDepth -= 1
        return .skipChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        loopDepth += 1
        for statement in node.body.statements { walk(statement) }
        loopDepth -= 1
        return .skipChildren
    }

    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        loopDepth += 1
        for statement in node.body.statements { walk(statement) }
        loopDepth -= 1
        return .skipChildren
    }

    // MARK: - Higher-order iteration as loops

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let methodName = memberAccess.declName.baseName.text
            let iteratingMethods: Set<String> = ["map", "flatMap", "compactMap", "filter", "forEach", "reduce"]

            if iteratingMethods.contains(methodName) {
                loopDepth += 1
                for arg in node.arguments { walk(arg) }
                if let trailing = node.trailingClosure { walk(trailing) }
                loopDepth -= 1
                return .skipChildren
            }
        }

        recordCallIfLocal(node)
        return .visitChildren
    }

    // MARK: - Skip nested functions

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    // MARK: - Call detection

    private func recordCallIfLocal(_ node: FunctionCallExprSyntax) {
        guard let calleeName = extractCalleeName(node) else { return }
        guard definedFunctions.contains(calleeName) else { return }

        let converter = SourceLocationConverter(fileName: "", tree: tree)
        let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line

        edges.append(CallEdge(
            caller: callerName,
            callee: calleeName,
            insideLoop: loopDepth > 0,
            line: line
        ))
    }

    private func extractCalleeName(_ node: FunctionCallExprSyntax) -> String? {
        if let ident = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            return ident.baseName.text
        }
        return nil
    }
}
