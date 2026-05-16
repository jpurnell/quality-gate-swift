import SwiftSyntax

/// Detects known algorithmic anti-patterns in a function body.
///
/// Identifies patterns like contains-in-filter, sort-in-loop, and
/// quadratic string concatenation that indicate potential performance issues.
struct PatternDetector {

    /// Scans a function body for anti-patterns.
    static func detect(body: CodeBlockSyntax, parameterTypes: [String: String] = [:]) -> [ComplexityPattern] {
        let suppressed = findSuppressedLines(in: body)
        let visitor = PatternVisitor(parameterTypes: parameterTypes, suppressedLines: suppressed)
        visitor.walk(body)
        return visitor.patterns
    }

    private static func findSuppressedLines(in body: CodeBlockSyntax) -> Set<Int> {
        var lines: Set<Int> = []
        let converter = SourceLocationConverter(fileName: "", tree: body.root)
        for token in body.tokens(viewMode: .sourceAccurate) {
            for piece in token.leadingTrivia {
                if case .lineComment(let text) = piece, text.contains("complexity-ok:") {
                    let tokenLine = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
                    lines.insert(tokenLine)
                }
            }
            for piece in token.trailingTrivia {
                if case .lineComment(let text) = piece, text.contains("complexity-ok:") {
                    let tokenLine = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
                    lines.insert(tokenLine)
                }
            }
        }
        return lines
    }

    /// Extracts parameter name-to-type mappings from a function signature.
    static func extractParameterTypes(from params: FunctionParameterListSyntax) -> [String: String] {
        var types: [String: String] = [:]
        for param in params {
            let name = (param.secondName ?? param.firstName).text
            let typeText = param.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
            types[name] = typeText
        }
        return types
    }
}

/// Walks a function body looking for known anti-patterns.
private final class PatternVisitor: SyntaxVisitor {
    var patterns: [ComplexityPattern] = []
    private var loopDepth: Int = 0
    private var inLoopBody: Bool = false
    private var stringVars: Set<String> = []
    private var setVars: Set<String> = []
    private var arrayVars: Set<String> = []
    private var suppressedLines: Set<Int> = []

    init(parameterTypes: [String: String] = [:], suppressedLines: Set<Int> = []) {
        self.suppressedLines = suppressedLines
        super.init(viewMode: .sourceAccurate)
        for (name, typeText) in parameterTypes {
            if typeText == "String" {
                stringVars.insert(name)
            }
            if typeText.hasPrefix("Set<") || typeText == "Set" {
                setVars.insert(name)
            }
            if typeText.hasPrefix("[") || typeText.hasPrefix("Array<") {
                arrayVars.insert(name)
            }
        }
    }

    // MARK: - Track variable types

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                let name = pattern.identifier.text

                if isStringInitializer(binding.initializer) {
                    stringVars.insert(name)
                }
                if let typeAnnotation = binding.typeAnnotation {
                    let typeText = typeAnnotation.type.description.trimmingCharacters(in: .whitespaces)
                    if typeText == "String" {
                        stringVars.insert(name)
                    }
                    if typeText.hasPrefix("Set<") || typeText == "Set" {
                        setVars.insert(name)
                    }
                    if typeText.hasPrefix("[") || typeText.hasPrefix("Array<") {
                        arrayVars.insert(name)
                    }
                }
                if isSetInitializer(binding.initializer) {
                    setVars.insert(name)
                }
                if isArrayInitializer(binding.initializer) {
                    arrayVars.insert(name)
                }
            }
        }
        return .visitChildren
    }

    // MARK: - Loop entry

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        loopDepth += 1
        let wasInLoop = inLoopBody
        inLoopBody = true
        for statement in node.body.statements {
            walk(statement)
        }
        inLoopBody = wasInLoop
        loopDepth -= 1
        return .skipChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        loopDepth += 1
        let wasInLoop = inLoopBody
        inLoopBody = true
        for statement in node.body.statements {
            walk(statement)
        }
        inLoopBody = wasInLoop
        loopDepth -= 1
        return .skipChildren
    }

    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        loopDepth += 1
        let wasInLoop = inLoopBody
        inLoopBody = true
        for statement in node.body.statements {
            walk(statement)
        }
        inLoopBody = wasInLoop
        loopDepth -= 1
        return .skipChildren
    }

    // MARK: - Higher-order methods that iterate (map, filter, forEach)

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let methodName = memberAccess.declName.baseName.text
            let iteratingMethods: Set<String> = ["map", "flatMap", "compactMap", "filter", "forEach", "reduce"]

            if iteratingMethods.contains(methodName) {
                loopDepth += 1
                let wasInLoop = inLoopBody
                inLoopBody = true

                for arg in node.arguments {
                    walk(arg)
                }
                if let trailing = node.trailingClosure {
                    walk(trailing)
                }

                inLoopBody = wasInLoop
                loopDepth -= 1
                return .skipChildren
            }
        }
        return .visitChildren
    }

    // MARK: - Detect contains calls inside loops

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard inLoopBody else { return .visitChildren }
        guard !hasSuppression(node) else { return .visitChildren }

        let methodName = node.declName.baseName.text

        if StdlibCostTable.isLinearSearch(methodName) {
            let receiverName = extractReceiverName(node.base)
            if isArrayReceiver(node.base) && !isSubstringContains(node) {
                let line = sourceLine(of: node)
                patterns.append(.containsInFilter(collection: receiverName, line: line))
            }
        }

        if StdlibCostTable.isSortOperation(methodName) {
            let line = sourceLine(of: node)
            patterns.append(.sortInLoop(line: line))
        }

        return .visitChildren
    }

    // MARK: - Detect string += in loops

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard inLoopBody else { return .visitChildren }
        guard !hasSuppression(node) else { return .visitChildren }

        if let op = node.operator.as(BinaryOperatorExprSyntax.self),
           op.operator.text == "+=" {
            if let leftName = extractIdentifierName(node.leftOperand),
               stringVars.contains(leftName) {
                let line = sourceLine(of: node)
                patterns.append(.quadraticStringConcat(line: line))
            }
        }

        return .visitChildren
    }

    // MARK: - Skip nested functions

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    // MARK: - Helpers

    private func extractReceiverName(_ base: ExprSyntax?) -> String {
        guard let base else { return "unknown" }
        if let ident = base.as(DeclReferenceExprSyntax.self) {
            return ident.baseName.text
        }
        if let member = base.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return base.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractIdentifierName(_ expr: ExprSyntax) -> String? {
        if let ident = expr.as(DeclReferenceExprSyntax.self) {
            return ident.baseName.text
        }
        return nil
    }


    private func isSubstringContains(_ node: MemberAccessExprSyntax) -> Bool {
        guard node.declName.baseName.text == "contains" else { return false }
        guard let call = node.parent?.as(FunctionCallExprSyntax.self) else { return false }
        let args = call.arguments
        guard let firstArg = args.first else { return false }
        if firstArg.expression.is(StringLiteralExprSyntax.self) {
            return true
        }
        if let argName = firstArg.expression.as(DeclReferenceExprSyntax.self),
           stringVars.contains(argName.baseName.text) {
            return true
        }
        return false
    }

    private func isArrayReceiver(_ base: ExprSyntax?) -> Bool {
        guard let base else { return false }
        if let ident = base.as(DeclReferenceExprSyntax.self) {
            return arrayVars.contains(ident.baseName.text)
        }
        if base.is(ArrayExprSyntax.self) {
            return true
        }
        return false
    }

    private func isSetInitializer(_ initializer: InitializerClauseSyntax?) -> Bool {
        guard let initializer else { return false }
        let valueText = initializer.value.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return valueText.hasPrefix("Set(") || valueText.hasPrefix("Set<")
    }

    private func isArrayInitializer(_ initializer: InitializerClauseSyntax?) -> Bool {
        guard let initializer else { return false }
        let valueText = initializer.value.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return valueText.hasPrefix("[") || valueText.hasPrefix("Array(")
    }

    private func isStringInitializer(_ initializer: InitializerClauseSyntax?) -> Bool {
        guard let initializer else { return false }
        let valueText = initializer.value.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return valueText.hasPrefix("\"") || valueText.hasPrefix("String(")
    }

    private func hasSuppression(_ node: some SyntaxProtocol) -> Bool {
        guard !suppressedLines.isEmpty else { return false }
        let line = sourceLine(of: node)
        return suppressedLines.contains(line)
    }

    private func sourceLine(of node: some SyntaxProtocol) -> Int {
        let converter = SourceLocationConverter(fileName: "", tree: node.root)
        return converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }
}
