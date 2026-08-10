import Foundation
import SwiftParser
import SwiftSyntax

/// A file-scope declaration in an assembled article, located in the *article*.
struct AssembledDeclaration {
    let name: String
    let kind: String
    let articleLine: Int
}

/// Collects file-scope declarations from an assembled article.
///
/// Detection is AST-based rather than textual, for two reasons that both cost a wrong
/// answer before they were understood.
///
/// **Comments are trivia, not tokens.** `// Create a retail model` is leading trivia
/// attached to a token, not part of any identifier node, so a visitor that examines
/// `IdentifierPatternSyntax` cannot see it. An earlier textual pass rewrote that comment
/// into `// Create a retail saasModel` while "renaming" a collision. With the AST the
/// failure is unrepresentable rather than merely unlikely.
///
/// **File scope means file scope.** A `let` inside an `if` at column zero is not a
/// top-level declaration, and indentation cannot tell you so. Scope depth is tracked by
/// pushing on the node kinds that actually introduce one, so `for (name, model) in …`
/// shadows rather than collides — which the textual version got wrong in both directions.
final class DeclarationCollector: SyntaxVisitor {

    private let converter: SourceLocationConverter
    private let article: (Int) -> Int
    private var scopeDepth = 0
    private(set) var declarations: [AssembledDeclaration] = []

    /// - Parameters:
    ///   - converter: Location converter for the assembled file.
    ///   - article: Maps an assembled line to its article line.
    init(converter: SourceLocationConverter, article: @escaping (Int) -> Int) {
        self.converter = converter
        self.article = article
        super.init(viewMode: .sourceAccurate)
    }

    private func record(_ name: String, _ node: some SyntaxProtocol, kind: String) {
        guard scopeDepth == 0 else { return }
        let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        declarations.append(
            AssembledDeclaration(name: name, kind: kind, articleLine: article(line)))
    }

    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        scopeDepth += 1
        return .visitChildren
    }
    override func visitPost(_ node: CodeBlockSyntax) { scopeDepth -= 1 }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        scopeDepth += 1
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { scopeDepth -= 1 }

    override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
        scopeDepth += 1
        return .visitChildren
    }
    override func visitPost(_ node: MemberBlockSyntax) { scopeDepth -= 1 }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            for name in Self.names(in: binding.pattern) {
                record(name, node, kind: node.bindingSpecifier.text)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node, kind: "func")
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node, kind: "struct")
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node, kind: "class")
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node, kind: "enum")
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node, kind: "protocol")
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node, kind: "actor")
        return .visitChildren
    }

    /// Every identifier bound by a pattern, including tuple destructuring.
    static func names(in pattern: PatternSyntax) -> [String] {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            return [identifier.identifier.text]
        }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.flatMap { names(in: $0.pattern) }
        }
        return []
    }
}
