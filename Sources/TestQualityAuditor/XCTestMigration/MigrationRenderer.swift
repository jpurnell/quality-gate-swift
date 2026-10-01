import SwiftSyntax

/// Writes the converted file, node by node, from a ``MigrationAnalysis``.
///
/// Rendering is the source text of the tree with some nodes replaced. A replaced node keeps its
/// own leading and trailing trivia: comments, indentation and blank lines around a converted
/// assertion are the author's, and stay where they were. Everything not replaced is copied
/// token by token, which is why a string literal (one token, however much XCTest it quotes)
/// cannot be rewritten.
final class MigrationRenderer {

    private let analysis: MigrationAnalysis
    /// Name tokens to respell: each test method's name.
    private var renamedTokens: [SyntaxIdentifier: String] = [:]
    /// While rendering an `XCTAssertThrowsError` closure body, what `$0` becomes.
    private var dollarZeroReplacement: String?

    init(analysis: MigrationAnalysis) {
        self.analysis = analysis
    }

    // MARK: - Rendering

    /// The source of `node`, converted.
    func render(_ node: Syntax) -> String {
        guard let token = node.as(TokenSyntax.self) else { return renderNode(node) }
        return renderToken(token)
    }

    /// The source of `node`, converted, without the node's own leading and trailing trivia.
    func trimmed(_ node: some SyntaxProtocol) -> String {
        strip(render(Syntax(node)), of: Syntax(node))
    }

    private func renderNode(_ node: Syntax) -> String {
        if analysis.removedStatements.contains(node.id) { return "" }
        if let replaced = replacement(for: node) {
            return node.leadingTrivia.description + replaced + node.trailingTrivia.description
        }
        if node.is(ClosureExprSyntax.self), dollarZeroReplacement != nil {
            // A nested closure's `$0` is its own.
            let saved = dollarZeroReplacement
            dollarZeroReplacement = nil
            defer { dollarZeroReplacement = saved }
            return renderChildren(node)
        }
        return renderChildren(node)
    }

    private func renderChildren(_ node: Syntax) -> String {
        node.children(viewMode: .sourceAccurate).map { render($0) }.joined()
    }

    private func renderToken(_ token: TokenSyntax) -> String {
        if let name = renamedTokens[token.id] {
            return token.leadingTrivia.description + name + token.trailingTrivia.description
        }
        if let replacement = dollarZeroReplacement, token.tokenKind == .dollarIdentifier("$0") {
            return token.leadingTrivia.description + replacement + token.trailingTrivia.description
        }
        return token.description
    }

    private func strip(_ text: String, of node: Syntax) -> String {
        var result = Substring(text)
        let leading = node.leadingTrivia.description
        let trailing = node.trailingTrivia.description
        if result.hasPrefix(leading) { result = result.dropFirst(leading.count) }
        if result.hasSuffix(trailing) { result = result.dropLast(trailing.count) }
        return String(result)
    }

    // MARK: - Replacements

    private func replacement(for node: Syntax) -> String? {
        if let importDecl = node.as(ImportDeclSyntax.self) {
            return importReplacement(importDecl)
        }
        if let classDecl = node.as(ClassDeclSyntax.self), let kind = analysis.suites[classDecl.id] {
            return suite(classDecl, kind: kind)
        }
        if let function = node.as(FunctionDeclSyntax.self) {
            return functionReplacement(function)
        }
        if let parameters = node.as(FunctionParameterListSyntax.self) {
            return SourceLocationParameters.replacement(for: parameters, render: { self.trimmed($0) })
        }
        if let returnStmt = node.as(ReturnStmtSyntax.self) {
            return returnedFailure(returnStmt)
        }
        if let call = node.as(FunctionCallExprSyntax.self) {
            return AssertionMapping.replacement(for: call, renderer: self)
        }
        return nil
    }

    private func importReplacement(_ node: ImportDeclSyntax) -> String? {
        guard node.path.trimmedDescription == "XCTest" else { return nil }
        let importsFoundation = node.root.as(SourceFileSyntax.self)?.statements.contains {
            $0.item.as(ImportDeclSyntax.self)?.path.trimmedDescription == "Foundation"
        } ?? false
        // XCTest re-exports Foundation, so a test that only imported XCTest was using it.
        return importsFoundation ? "import Testing" : "import Foundation\nimport Testing"
    }

    private func suite(_ node: ClassDeclSyntax, kind: MigrationAnalysis.SuiteKind) -> String {
        var words = ["@Suite"]
        if !node.attributes.isEmpty { words.append(trimmed(node.attributes)) }
        for modifier in node.modifiers where modifier.name.tokenKind != .keyword(.final) {
            words.append(modifier.trimmedDescription)
        }
        switch kind {
        case .structure: words.append("struct")
        case .finalClass: words += ["final", "class"]
        }
        words.append(node.name.text + (node.genericParameterClause?.trimmedDescription ?? ""))

        var header = words.joined(separator: " ")
        let inherited = node.inheritanceClause?.inheritedTypes
            .map { $0.type.trimmedDescription }
            .filter { $0 != "XCTestCase" } ?? []
        if !inherited.isEmpty { header += ": " + inherited.joined(separator: ", ") }
        if let generics = node.genericWhereClause { header += " " + generics.trimmedDescription }
        return header + " " + trimmed(node.memberBlock)
    }

    private func functionReplacement(_ node: FunctionDeclSyntax) -> String? {
        if let name = analysis.testNames[node.id] {
            renamedTokens[node.name.id] = name
            return "@Test " + strip(renderChildren(Syntax(node)), of: Syntax(node))
        }
        guard let lifecycle = analysis.lifecycles[node.id], let body = node.body else { return nil }
        let attributes = node.attributes.isEmpty ? "" : trimmed(node.attributes) + " "
        switch lifecycle {
        case .initializer:
            let effects = node.signature.effectSpecifiers.map { " " + $0.trimmedDescription } ?? ""
            return attributes + "init()" + effects + " " + trimmed(body)
        case .deinitializer:
            return attributes + "deinit " + trimmed(body)
        }
    }

    /// `return XCTFail("…")`: `XCTFail` returned `Void`, so this returned it. `Issue.record`
    /// returns the issue, which a `Void` function cannot.
    private func returnedFailure(_ node: ReturnStmtSyntax) -> String? {
        guard let call = node.expression?.as(FunctionCallExprSyntax.self),
              call.calledExpression.trimmedDescription == "XCTFail",
              let recorded = AssertionMapping.replacement(for: call, renderer: self)
        else { return nil }
        return recorded + "; return"
    }

    // MARK: - For the assertion table

    /// Renders a closure's statements with `$0` at their own level spelled `name`.
    func renderStatements(of closure: ClosureExprSyntax, dollarZeroAs name: String?) -> String {
        let saved = dollarZeroReplacement
        dollarZeroReplacement = name
        defer { dollarZeroReplacement = saved }
        return render(Syntax(closure.statements))
    }

    /// Functions this file declares `throws`.
    var throwingFunctions: Set<String> { analysis.throwingFunctions }
}
