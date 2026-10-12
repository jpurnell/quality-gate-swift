import SwiftSyntax

/// Writes the converted file, node by node, from a ``MigrationAnalysis``.
///
/// Rendering is the source text of the tree with some nodes replaced. A replaced node keeps its
/// own leading and trailing trivia: comments, indentation and blank lines around a converted
/// assertion are the author's, and stay where they were. Everything not replaced is copied
/// token by token, which is why a string literal (one token, however much XCTest it quotes)
/// cannot be rewritten.
///
/// ## What an assertion cannot hold
///
/// `XCTAssert*` took its arguments as autoclosures of a function. `#expect` and `#require`
/// are macros, and three things that compiled inside the function do not compile inside the
/// macro: a mutating call, a `#require` inside a `#require`, and a property read off a closure
/// that uses optional chaining. Each is bound to a `let` on the line before
/// (``bind(_:named:from:)``), which is where the statement frames below come in.
final class MigrationRenderer {

    private let analysis: MigrationAnalysis
    /// Name tokens to respell: each test method's name.
    private var renamedTokens: [SyntaxIdentifier: String] = [:]
    /// While rendering an `XCTAssertThrowsError` closure body, what `$0` becomes.
    private var dollarZeroReplacement: String?
    /// Nodes whose value has been bound ahead of their statement, and the binding's name.
    private var substitutions: [SyntaxIdentifier: String] = [:]
    /// Tokens after which `throws` is written: the end of a signature that gained it.
    private var throwsInsertions: Set<SyntaxIdentifier> = []
    /// Handler closures whose statements move into an `if` body.
    private var inlinedClosures: Set<SyntaxIdentifier> = []
    private var names: HoistedName.Allocator

    /// One statement being rendered, and what has to be declared before it.
    private struct Frame {
        let statement: CodeBlockItemSyntax
        /// How many assertion macros enclosed the statement when it was reached. Above zero
        /// the statement is inside a closure inside an assertion, and a binding placed before
        /// it would still be inside the macro.
        let macroDepth: Int
        var bindings: [String] = []
    }

    /// Statements being rendered, innermost last. `nil` marks a member declaration, which has
    /// no statement to put a binding in front of.
    private var frames: [Frame?] = []

    /// Whether the code being rendered may throw.
    private enum Throwing {
        /// It already does: a `throws` function, or a `do` with a `catch`.
        case yes
        /// A test method or `setUp`, which can be given `throws`: nothing calls it.
        case canBeAdded
        /// A closure. Whether it may throw is decided by whatever takes it.
        case closure
        /// A function with callers, named here, or a `deinit`.
        case fixed(String)
        /// A stored property's initial value, or anything else outside a function.
        case notInAFunction
    }

    private struct Scope {
        let throwing: Throwing
        /// Locals declared `var`, and `inout` parameters. A method called on one may mutate it.
        var mutableLocals: Set<String> = []
        var needsThrows = false
    }

    private var scopes: [Scope] = []

    /// How many `#expect`/`#require` argument lists enclose what is being rendered.
    private(set) var macroDepth = 0
    /// How many of those are `#require`, which cannot contain another `#require`.
    private(set) var requireDepth = 0

    init(analysis: MigrationAnalysis) {
        self.analysis = analysis
        self.names = HoistedName.Allocator(taken: analysis.namesInUse)
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
        if let bound = substitutions[node.id] {
            return node.leadingTrivia.description + bound + node.trailingTrivia.description
        }
        if let statement = node.as(CodeBlockItemSyntax.self) { return renderStatement(statement) }
        if node.is(MemberBlockItemSyntax.self) {
            frames.append(nil)
            scopes.append(Scope(throwing: .notInAFunction))
            defer {
                frames.removeLast()
                scopes.removeLast()
            }
            return renderUnframed(node)
        }
        return renderUnframed(node)
    }

    private func renderUnframed(_ node: Syntax) -> String {
        if let replaced = replacement(for: node) {
            return node.leadingTrivia.description + replaced + node.trailingTrivia.description
        }
        if let closure = node.as(ClosureExprSyntax.self) { return renderClosure(closure) }
        if let doStmt = node.as(DoStmtSyntax.self), !doStmt.catchClauses.isEmpty {
            return renderCatching(doStmt)
        }
        return renderChildren(node)
    }

    /// A statement, with whatever its assertions needed bound on the lines before it.
    private func renderStatement(_ statement: CodeBlockItemSyntax) -> String {
        frames.append(Frame(statement: statement, macroDepth: macroDepth))
        let body = renderUnframed(Syntax(statement))
        guard let frame = frames.removeLast(), !frame.bindings.isEmpty else { return body }

        let leading = statement.leadingTrivia.description
        let indentation = String(leading.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        let core = body.hasPrefix(leading) ? String(body.dropFirst(leading.count)) : body
        return leading + frame.bindings.map { $0 + "\n" + indentation }.joined() + core
    }

    private func renderClosure(_ node: ClosureExprSyntax) -> String {
        // A nested closure's `$0` is its own.
        let saved = dollarZeroReplacement
        dollarZeroReplacement = nil
        scopes.append(Scope(throwing: .closure))
        defer {
            scopes.removeLast()
            dollarZeroReplacement = saved
        }
        return renderChildren(Syntax(node))
    }

    /// A `do` with a `catch`: whatever its body throws is handled, so a `try` may be added there.
    private func renderCatching(_ node: DoStmtSyntax) -> String {
        node.children(viewMode: .sourceAccurate).map { child in
            guard child.id == node.body.id else { return render(child) }
            return throwingScope { render(child) }
        }.joined()
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
        if throwsInsertions.contains(token.id) {
            return token.leadingTrivia.description + token.text + " throws" + token.trailingTrivia.description
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
        if let doStmt = node.as(DoStmtSyntax.self) {
            return ExpectedThrow.replacement(for: doStmt, renderer: self)
        }
        if let tryExpr = node.as(TryExprSyntax.self) {
            return boundUnwrap(tryExpr)
        }
        if let call = node.as(FunctionCallExprSyntax.self), !analysis.keptCalls.contains(call.id) {
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

    /// Any function: a test gains `@Test`, a lifecycle method becomes `init` or `deinit`, and
    /// each of those gains `throws` if something in its body turned into `try #require`.
    ///
    /// The body is rendered first. Whether the signature needs `throws` is only known once
    /// every assertion in the body has been written.
    private func functionReplacement(_ node: FunctionDeclSyntax) -> String? {
        let testName = analysis.testNames[node.id]
        let lifecycle = analysis.lifecycles[node.id]
        let effects = node.signature.effectSpecifiers

        let throwing: Throwing
        if effects?.throwsClause != nil {
            throwing = .yes
        } else if lifecycle == .deinitializer {
            throwing = .fixed("deinit")
        } else if testName != nil || lifecycle == .initializer {
            throwing = .canBeAdded
        } else {
            throwing = .fixed(node.name.text)
        }
        scopes.append(Scope(throwing: throwing, mutableLocals: MutableLocals.names(in: node)))
        // A binding's name has to be unique in its function, not in the file: `next` in one
        // test does not make the next test's `next2`.
        let namesOutside = names
        let body = node.body.map { render(Syntax($0)) }
        names = namesOutside
        let needsThrows = scopes.removeLast().needsThrows

        if let lifecycle, let block = node.body, let body {
            let attributes = node.attributes.isEmpty ? "" : trimmed(node.attributes) + " "
            switch lifecycle {
            case .initializer:
                var signature = effects.map { " " + $0.trimmedDescription } ?? ""
                if needsThrows { signature += " throws" }
                return attributes + "init()" + signature + " " + strip(body, of: Syntax(block))
            case .deinitializer:
                return attributes + "deinit " + strip(body, of: Syntax(block))
            }
        }

        if needsThrows {
            let last = effects?.asyncSpecifier ?? node.signature.parameterClause.rightParen
            throwsInsertions.insert(last.id)
        }
        if let testName { renamedTokens[node.name.id] = testName }
        let text = node.children(viewMode: .sourceAccurate).map { child in
            guard let body, child.id == node.body?.id else { return render(child) }
            return body
        }.joined()
        let function = strip(text, of: Syntax(node))
        guard testName != nil else { return function }
        let traits = analysis.traits[node.id].map { "(\($0))" } ?? ""
        return "@Test\(traits) " + function
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

    /// `try XCTUnwrap(x)` inside another assertion: once the unwrap is bound on the line
    /// before, what is left here is a name, and a `try` in front of a name is a warning.
    private func boundUnwrap(_ node: TryExprSyntax) -> String? {
        guard macroDepth > 0, node.questionOrExclamationMark == nil,
              let call = node.expression.as(FunctionCallExprSyntax.self),
              call.calledExpression.trimmedDescription == "XCTUnwrap"
        else { return nil }
        let inner = trimmed(call)
        return inner.hasPrefix("#require(") ? "try " + inner : inner
    }

    // MARK: - For the assertion table

    /// Renders a closure's statements with `$0` at their own level spelled `name`.
    ///
    /// The statements are headed for an `if` body in the enclosing function, so they are
    /// rendered in that function's scope, not as a closure.
    func renderStatements(of closure: ClosureExprSyntax, dollarZeroAs name: String?) -> String {
        let saved = dollarZeroReplacement
        dollarZeroReplacement = name
        inlinedClosures.insert(closure.id)
        defer { dollarZeroReplacement = saved }
        return render(Syntax(closure.statements))
    }

    /// Functions this file declares `throws`.
    var throwingFunctions: Set<String> { analysis.throwingFunctions }

    /// Renders with one more assertion macro around what `body` writes.
    func withinMacro<T>(requiring: Bool, _ body: () -> T) -> T {
        macroDepth += 1
        if requiring { requireDepth += 1 }
        defer {
            macroDepth -= 1
            if requiring { requireDepth -= 1 }
        }
        return body()
    }

    /// Renders the body of a closure handed to `#expect(throws:)`, where a `try` is at home
    /// and nothing is nested in a macro's condition.
    func throwingScope<T>(_ body: () -> T) -> T {
        let saved = (macroDepth, requireDepth)
        (macroDepth, requireDepth) = (0, 0)
        scopes.append(Scope(throwing: .yes))
        defer {
            scopes.removeLast()
            (macroDepth, requireDepth) = saved
        }
        return body()
    }

    /// Binds `expression` to a new `let` on the line before the statement being rendered.
    ///
    /// - Parameters:
    ///   - expression: The converted source of the value.
    ///   - base: What to call it; made unique in the file.
    ///   - node: Where the value was written. It must be evaluated exactly once whenever its
    ///     statement runs, or computing it earlier changes the test.
    /// - Returns: The binding's name, or `nil` when the value cannot be moved. The caller then
    ///   declines the file or leaves the value where it was.
    func bind(_ expression: String, named base: String, from node: Syntax) -> String? {
        guard let index = frames.indices.last, let frame = frames[index],
              frame.macroDepth == 0,
              HoistPosition.isUnconditional(node, in: frame.statement),
              HoistPosition.allowsStatementsBefore(frame.statement, inlined: inlinedClosures)
        else { return nil }
        let name = names.fresh(base)
        frames[index]?.bindings.append("let \(name) = \(expression)")
        return name
    }

    /// Spells `node` as `name` wherever it is rendered from now on.
    func substitute(_ node: Syntax, with name: String) {
        substitutions[node.id] = name
    }

    /// Makes the enclosing function `throws` if it can be, for a `try #require` written into it.
    ///
    /// - Returns: `false`, having declined the file, when the code is somewhere a `try` cannot
    ///   be added without changing callers the conversion cannot see.
    func requireThrows(for construct: String, at node: Syntax) -> Bool {
        guard let index = scopes.indices.last else {
            decline("\(construct) outside a function: as `try #require` it needs somewhere to throw from.", at: node)
            return false
        }
        switch scopes[index].throwing {
        case .yes:
            return true
        case .canBeAdded:
            scopes[index].needsThrows = true
            return true
        case .closure:
            decline("\(construct) inside a closure: as `try #require` it needs the closure to throw, and whatever runs the closure to `try`. Move the check out of the closure, or collect what the closure sees and check it afterwards.", at: node)
        case .fixed(let name):
            decline("\(construct) in `\(name)`: as `try #require` it needs `\(name)` to throw, and `\(name)` cannot be changed without changing whatever calls it.", at: node)
        case .notInAFunction:
            decline("\(construct) outside a function: as `try #require` it needs somewhere to throw from.", at: node)
        }
        return false
    }

    /// Whether `name` is a local the enclosing function may mutate.
    func isMutableLocal(_ name: String) -> Bool {
        scopes.contains { $0.mutableLocals.contains(name) }
    }

    /// Records a construct that stops this file's conversion.
    func decline(_ message: String, at node: Syntax) {
        analysis.decline(message, at: node)
    }
}

/// The names a function can mutate in place: its `var` locals and `inout` parameters.
private final class MutableLocals: SyntaxVisitor {
    private var found: Set<String> = []
    private var inVariable = false

    static func names(in function: FunctionDeclSyntax) -> Set<String> {
        let visitor = MutableLocals(viewMode: .sourceAccurate)
        for parameter in function.signature.parameterClause.parameters
        where parameter.type.trimmedDescription.hasPrefix("inout ") {
            visitor.found.insert((parameter.secondName ?? parameter.firstName).text)
        }
        if let body = function.body { visitor.walk(body) }
        return visitor.found
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        inVariable = node.bindingSpecifier.tokenKind == .keyword(.var)
        return .visitChildren
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        inVariable = false
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        if inVariable { found.insert(node.identifier.text) }
        return .visitChildren
    }

    override func visit(_ node: InitializerClauseSyntax) -> SyntaxVisitorContinueKind {
        // The initial value is an expression, and a `let` inside a closure there is not this `var`.
        let saved = inVariable
        inVariable = false
        defer { inVariable = saved }
        walk(node.value)
        return .skipChildren
    }
}
