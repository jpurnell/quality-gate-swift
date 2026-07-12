import Foundation
import QualityGateCore
import SwiftSyntax

/// Collects `DeclReferenceExprSyntax` base names, used to decide whether a
/// closure parameter is ever referenced in the closure body.
final class IdiomReferenceCollector: SyntaxVisitor {
    /// The set of referenced identifier names (backticks stripped).
    private(set) var names: Set<String> = []

    override func visitPost(_ node: DeclReferenceExprSyntax) {
        names.insert(IdiomSyntaxVisitor.strippingBackticks(node.baseName.text))
    }
}

/// SwiftSyntax visitor implementing the AST-backed idiom rules.
final class IdiomSyntaxVisitor: SyntaxVisitor {
    private let config: IdiomConfig
    private let converter: SourceLocationConverter
    /// Raw findings accumulated during the walk.
    private(set) var findings: [IdiomFinding] = []

    /// Creates a visitor for one parsed source file.
    init(config: IdiomConfig, converter: SourceLocationConverter) {
        self.config = config
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    /// Strips backtick escapes from an identifier.
    static func strippingBackticks(_ name: String) -> String {
        name.replacingOccurrences(of: "`", with: "")
    }

    private func record(
        _ ruleId: String,
        _ message: String,
        at node: some SyntaxProtocol,
        fix: String? = nil
    ) {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        findings.append(IdiomFinding(
            ruleId: ruleId,
            message: message,
            lineNumber: location.line,
            columnNumber: location.column,
            suggestedFix: fix
        ))
    }

    // MARK: - Sequence-based rules (unfolded operator sequences)

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        scanEmptyCount(elements)
        scanNilCoalescing(elements)
        scanContainsOverFirst(elements)
        scanShorthandAssignment(elements)
        return .visitChildren
    }

    /// `idiom.empty-count`: `.count == 0`, `.count != 0`, `.count > 0`.
    private func scanEmptyCount(_ elements: [ExprSyntax]) {
        guard elements.count >= 3 else { return }
        for index in 0...(elements.count - 3) {
            guard let member = elements[index].as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "count",
                  let base = member.base,
                  let opText = elements[index + 1].as(BinaryOperatorExprSyntax.self)?.operator.text,
                  opText == "==" || opText == "!=" || opText == ">",
                  let literal = elements[index + 2].as(IntegerLiteralExprSyntax.self),
                  literal.literal.text == "0"
            else { continue }
            let baseText = base.trimmedDescription
            let fix = opText == "==" ? "\(baseText).isEmpty" : "!\(baseText).isEmpty"
            record(
                "idiom.empty-count",
                "Prefer 'isEmpty' over comparing 'count' to zero.",
                at: member,
                fix: fix
            )
        }
    }

    /// `idiom.redundant-nil-coalescing`: `expr ?? nil`.
    private func scanNilCoalescing(_ elements: [ExprSyntax]) {
        guard elements.count >= 3 else { return }
        for index in 0...(elements.count - 3) {
            guard let opNode = elements[index + 1].as(BinaryOperatorExprSyntax.self),
                  opNode.operator.text == "??",
                  elements[index + 2].is(NilLiteralExprSyntax.self)
            else { continue }
            record(
                "idiom.redundant-nil-coalescing",
                "'?? nil' is redundant — the left operand is already optional.",
                at: elements[index],
                fix: elements[index].trimmedDescription
            )
        }
    }

    /// `idiom.contains-over-first`: `.first(where:) != nil` / `== nil`.
    private func scanContainsOverFirst(_ elements: [ExprSyntax]) {
        guard elements.count >= 3 else { return }
        for index in 0...(elements.count - 3) {
            guard let call = elements[index].as(FunctionCallExprSyntax.self),
                  let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.text == "first",
                  let base = member.base,
                  call.trailingClosure == nil,
                  call.arguments.count == 1,
                  let firstArg = call.arguments.first,
                  firstArg.label?.text == "where",
                  let opText = elements[index + 1].as(BinaryOperatorExprSyntax.self)?.operator.text,
                  opText == "!=" || opText == "==",
                  elements[index + 2].is(NilLiteralExprSyntax.self)
            else { continue }
            let containsCall = "\(base.trimmedDescription).contains(where: \(firstArg.expression.trimmedDescription))"
            let fix = opText == "!=" ? containsCall : "!\(containsCall)"
            record(
                "idiom.contains-over-first",
                "Prefer 'contains(where:)' over comparing 'first(where:)' to nil.",
                at: call,
                fix: fix
            )
        }
    }

    /// `idiom.shorthand-operator`: `x = x + e` and friends (same lvalue, single operand).
    private func scanShorthandAssignment(_ elements: [ExprSyntax]) {
        guard elements.count == 5,
              elements[1].is(AssignmentExprSyntax.self),
              let opText = elements[3].as(BinaryOperatorExprSyntax.self)?.operator.text,
              opText == "+" || opText == "-" || opText == "*" || opText == "/",
              elements[0].is(DeclReferenceExprSyntax.self) || elements[0].is(MemberAccessExprSyntax.self),
              elements[0].trimmedDescription == elements[2].trimmedDescription
        else { return }
        let lvalue = elements[0].trimmedDescription
        record(
            "idiom.shorthand-operator",
            "Prefer '\(opText)=' compound assignment over '\(lvalue) = \(lvalue) \(opText) …'.",
            at: elements[0],
            fix: "\(lvalue) \(opText)= \(elements[4].trimmedDescription)"
        )
    }

    // MARK: - Variable declarations

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        checkRedundantOptionalInit(node)
        checkRedundantDiscardableLet(node)
        for binding in node.bindings {
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                checkIdentifier(pattern.identifier, kind: "Variable")
            }
            checkImplicitGetter(binding.accessorBlock)
        }
        return .visitChildren
    }

    /// `idiom.redundant-optional-init`: `var x: T? = nil`.
    private func checkRedundantOptionalInit(_ node: VariableDeclSyntax) {
        guard node.bindingSpecifier.tokenKind == .keyword(.var) else { return }
        for binding in node.bindings {
            guard let optionalType = binding.typeAnnotation?.type.as(OptionalTypeSyntax.self),
                  let initializer = binding.initializer,
                  initializer.value.is(NilLiteralExprSyntax.self)
            else { continue }
            var fix: String?
            if node.bindings.count == 1,
               node.attributes.isEmpty,
               node.modifiers.isEmpty,
               let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                fix = "var \(pattern.identifier.text): \(optionalType.trimmedDescription)"
            }
            record(
                "idiom.redundant-optional-init",
                "Initializing an optional 'var' with 'nil' is redundant.",
                at: binding,
                fix: fix
            )
        }
    }

    /// `idiom.redundant-discardable-let`: `let _ = expr`.
    private func checkRedundantDiscardableLet(_ node: VariableDeclSyntax) {
        guard node.bindingSpecifier.tokenKind == .keyword(.let),
              node.bindings.count == 1,
              let binding = node.bindings.first,
              binding.pattern.is(WildcardPatternSyntax.self),
              let initializer = binding.initializer
        else { return }
        let isPlain = binding.typeAnnotation == nil && node.attributes.isEmpty && node.modifiers.isEmpty
        record(
            "idiom.redundant-discardable-let",
            "Prefer '_ = expression' over 'let _ = expression'.",
            at: node,
            fix: isPlain ? "_ = \(initializer.value.trimmedDescription)" : nil
        )
    }

    /// `idiom.implicit-getter`: a lone `get { … }` accessor block.
    private func checkImplicitGetter(_ accessorBlock: AccessorBlockSyntax?) {
        guard let accessorBlock,
              case .accessors(let accessorList) = accessorBlock.accessors,
              accessorList.count == 1,
              let accessor = accessorList.first,
              accessor.accessorSpecifier.tokenKind == .keyword(.get),
              accessor.effectSpecifiers == nil,
              let body = accessor.body
        else { return }
        record(
            "idiom.implicit-getter",
            "Computed property with a lone 'get' block — drop the 'get' wrapper.",
            at: accessor,
            fix: body.statements.trimmedDescription
        )
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        checkImplicitGetter(node.accessorBlock)
        return .visitChildren
    }

    // MARK: - Identifier and type names

    /// `idiom.identifier-name`: lowercase start and minimum length.
    private func checkIdentifier(_ token: TokenSyntax, kind: String) {
        let raw = token.text
        if raw.hasPrefix("`") { return } // backtick-escaped keywords are deliberate
        guard let first = raw.first, first.isLetter || first == "_" else { return } // operators
        let stripped = raw.drop(while: { $0 == "_" })
        guard let head = stripped.first else { return } // bare underscores are wildcards
        if head.isUppercase {
            record(
                "idiom.identifier-name",
                "\(kind) name '\(raw)' should start with a lowercase letter.",
                at: token
            )
        }
        if raw.count < config.minIdentifierLength, !config.allowedShortIdentifiers.contains(raw) {
            record(
                "idiom.identifier-name",
                "\(kind) name '\(raw)' is shorter than the minimum length \(config.minIdentifierLength).",
                at: token
            )
        }
    }

    /// `idiom.type-name`: UpperCamelCase, bounded length.
    private func checkTypeName(_ token: TokenSyntax, kind: String) {
        let raw = token.text
        if raw.hasPrefix("`") { return }
        let stripped = raw.drop(while: { $0 == "_" })
        guard let head = stripped.first else { return }
        if !head.isUppercase || stripped.contains("_") {
            record(
                "idiom.type-name",
                "\(kind) name '\(raw)' should be UpperCamelCase.",
                at: token
            )
        }
        if raw.count > config.maxTypeNameLength {
            record(
                "idiom.type-name",
                "\(kind) name '\(raw)' is \(raw.count) characters (max \(config.maxTypeNameLength)).",
                at: token
            )
        }
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        checkTypeName(node.name, kind: "Struct")
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        checkTypeName(node.name, kind: "Class")
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        checkTypeName(node.name, kind: "Actor")
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        checkTypeName(node.name, kind: "Protocol")
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        checkTypeName(node.name, kind: "Typealias")
        return .visitChildren
    }

    // MARK: - Functions and initializers

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        checkIdentifier(node.name, kind: "Function")
        for parameter in node.signature.parameterClause.parameters {
            let nameToken = parameter.secondName ?? parameter.firstName
            if nameToken.text != "_" {
                checkIdentifier(nameToken, kind: "Parameter")
            }
        }
        checkBodyLength(node.body, declName: node.name.text, node: node)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        checkBodyLength(node.body, declName: "init", node: node)
        return .visitChildren
    }

    /// `idiom.function-body-length`: lines strictly between the body braces.
    private func checkBodyLength(_ body: CodeBlockSyntax?, declName: String, node: some SyntaxProtocol) {
        guard let body else { return }
        let startLine = converter.location(for: body.leftBrace.positionAfterSkippingLeadingTrivia).line
        let endLine = converter.location(for: body.rightBrace.positionAfterSkippingLeadingTrivia).line
        let bodyLines = max(0, endLine - startLine - 1)
        if bodyLines > config.maxFunctionBodyLength {
            record(
                "idiom.function-body-length",
                "Body of '\(declName)' spans \(bodyLines) lines (max \(config.maxFunctionBodyLength)).",
                at: node
            )
        }
    }

    // MARK: - Enums

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        checkTypeName(node.name, kind: "Enum")
        let isStringRawValue = node.inheritanceClause?.inheritedTypes.contains {
            $0.type.trimmedDescription == "String"
        } ?? false
        for member in node.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                checkIdentifier(element.name, kind: "Enum case")
                guard isStringRawValue,
                      let rawValue = element.rawValue,
                      let stringLiteral = rawValue.value.as(StringLiteralExprSyntax.self),
                      stringLiteral.segments.count == 1,
                      let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self),
                      segment.content.text == element.name.text
                else { continue }
                record(
                    "idiom.redundant-string-enum-value",
                    "Raw value \"\(segment.content.text)\" duplicates the case name and can be removed.",
                    at: element,
                    fix: "case \(element.name.text)"
                )
            }
        }
        return .visitChildren
    }

    // MARK: - Closures

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        checkUnusedClosureParameters(node)
        return .visitChildren
    }

    /// `idiom.unused-closure-parameter`: named parameter never referenced in the body.
    private func checkUnusedClosureParameters(_ node: ClosureExprSyntax) {
        guard let parameterClause = node.signature?.parameterClause else { return }
        var parameterTokens: [TokenSyntax] = []
        switch parameterClause {
        case .simpleInput(let shorthandList):
            parameterTokens = shorthandList.map { $0.name }
        case .parameterClause(let clause):
            parameterTokens = clause.parameters.map { $0.secondName ?? $0.firstName }
        }
        let named = parameterTokens.filter { $0.text != "_" }
        guard !named.isEmpty else { return }
        let collector = IdiomReferenceCollector(viewMode: .sourceAccurate)
        collector.walk(node.statements)
        for token in named where !collector.names.contains(Self.strippingBackticks(token.text)) {
            record(
                "idiom.unused-closure-parameter",
                "Closure parameter '\(token.text)' is never used — replace it with '_'.",
                at: token,
                fix: "_"
            )
        }
    }

    // MARK: - Calls

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let replacements: [String: String] = [
                "arc4random": "UInt32.random(in:)",
                "arc4random_uniform": "Int.random(in: 0..<n)",
                "drand48": "Double.random(in: 0..<1)",
            ]
            if let replacement = replacements[reference.baseName.text] {
                record(
                    "idiom.legacy-random",
                    "Legacy C random API '\(reference.baseName.text)' — prefer Swift's '\(replacement)'.",
                    at: node
                )
            }
        }
        return .visitChildren
    }

    // MARK: - Types

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        guard let clause = node.genericArgumentClause else { return .visitChildren }
        let arguments = Array(clause.arguments)
        switch (node.name.text, arguments.count) {
        case ("Array", 1):
            record(
                "idiom.syntactic-sugar",
                "Prefer '[T]' over 'Array<T>'.",
                at: node,
                fix: "[\(arguments[0].argument.trimmedDescription)]"
            )
        case ("Dictionary", 2):
            record(
                "idiom.syntactic-sugar",
                "Prefer '[K: V]' over 'Dictionary<K, V>'.",
                at: node,
                fix: "[\(arguments[0].argument.trimmedDescription): \(arguments[1].argument.trimmedDescription)]"
            )
        case ("Optional", 1):
            let inner = arguments[0].argument.trimmedDescription
            let needsParens = inner.contains(" ")
            record(
                "idiom.syntactic-sugar",
                "Prefer 'T?' over 'Optional<T>'.",
                at: node,
                fix: needsParens ? "(\(inner))?" : "\(inner)?"
            )
        default:
            break
        }
        return .visitChildren
    }
}
