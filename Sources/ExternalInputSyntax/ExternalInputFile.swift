import QualityGateCore
import SwiftSyntax

/// `ExternalInput` read off a SwiftSyntax tree: one per file, asked about expressions in it.
///
/// Built once per file — it collects the file's imports, the types it declares as Vapor
/// `Content`, and the ArgumentParser properties of each type — and then answers for any
/// expression in that file by describing it as an `ExternalInput/Expression` and building the
/// `ExternalInput/Scope` around it.
///
/// The scope is the *function* the expression is in: the innermost `func`, `init`, accessor,
/// subscript or `deinit`; failing that the outermost closure (a closure stored in a property);
/// failing that the file's top-level code. Closures between that function and the expression
/// add their parameters. Bindings are every `let`/`var` with an initialiser, `if let`/`guard let`,
/// `case let` pattern and `for` loop declared earlier in that function — not inside a nested
/// `func`, which is another function — the latest per name. A binding whose own initialiser
/// contains the expression is not in scope for it.
///
/// ## Usage
///
/// A visitor builds one per file and asks about the argument it cares about — here every
/// `format:` argument, which for `NSExpression(format: formula)` in an MCP tool answers
/// "an MCP tool argument, via `arguments: [String: AnyCodable]?`":
///
/// ```swift
/// import SwiftSyntax
///
/// final class FormatSources: SyntaxVisitor {
///     let file: ExternalInputFile
///     var found: [String] = []
///
///     init(_ tree: SourceFileSyntax) {
///         file = ExternalInputFile(tree)
///         super.init(viewMode: .sourceAccurate)
///     }
///
///     override func visit(_ node: LabeledExprSyntax) -> SyntaxVisitorContinueKind {
///         if node.label?.text == "format", let trace = file.trace(of: node.expression) {
///             found.append("\(trace.kind.phrase), via \(trace.evidence)")
///         }
///         return .visitChildren
///     }
/// }
/// ```
public struct ExternalInputFile: Sendable {
    /// The vocabulary in force: the caller's, plus this file's `Content` types.
    public let vocabulary: ExternalInput.Vocabulary
    /// The modules the file imports.
    public let imports: Set<String>
    /// ArgumentParser properties, by the name of the type (or extended type) declaring them.
    let commandLineProperties: [String: Set<String>]

    /// Collects the file-wide facts.
    public init(_ file: SourceFileSyntax, vocabulary: ExternalInput.Vocabulary = .standard) {
        let facts = FileFacts(viewMode: .sourceAccurate)
        facts.walk(file)
        self.vocabulary = vocabulary.addingContentTypes(facts.contentTypes)
        self.imports = facts.imports
        self.commandLineProperties = facts.commandLineProperties
    }

    /// Where `expression` derives from — see `ExternalInput/derivation(of:in:vocabulary:)`.
    public func derivation(of expression: ExprSyntax) -> ExternalInput.Derivation? {
        ExternalInput.derivation(of: Self.describe(expression), in: scope(at: expression), vocabulary: vocabulary)
    }

    /// The external source `expression` derives from, if any.
    public func trace(of expression: ExprSyntax) -> ExternalInput.Trace? {
        guard case .external(let trace)? = derivation(of: expression) else { return nil }
        return trace
    }

    // MARK: - Describing an expression

    /// `expression` as the model reads it.
    public static func describe(_ expression: ExprSyntax) -> ExternalInput.Expression {
        describe(expression, depth: 0)
    }

    static func describe(_ expression: ExprSyntax, depth: Int) -> ExternalInput.Expression {
        guard depth < 64 else { return .opaque }
        let next = depth + 1
        if let wrapped = transparentInner(expression) {
            return describe(wrapped, depth: next)
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return .name(reference.baseName.text)
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return .member(member.base.map { describe($0, depth: next) }, member.declName.baseName.text)
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return .call(describe(call.calledExpression, depth: next), arguments(call.arguments, depth: next))
        }
        if let subscriptCall = expression.as(SubscriptCallExprSyntax.self) {
            return .subscripted(describe(subscriptCall.calledExpression, depth: next),
                                arguments(subscriptCall.arguments, depth: next))
        }
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            let holes = literal.segments.compactMap { $0.as(ExpressionSegmentSyntax.self) }
            guard !holes.isEmpty else { return .literal }
            return .interpolated(holes.flatMap { $0.expressions.map { describe($0.expression, depth: next) } })
        }
        if let parts = combinedParts(expression) {
            return .combined(parts.map { describe($0, depth: next) })
        }
        if isLiteral(expression) {
            return .literal
        }
        return .opaque
    }

    /// The expression inside one that does not change the value: `try`, `await`, `?`, `!`,
    /// parentheses, and a sequence that is one operand and a cast.
    public static func transparentInner(_ expression: ExprSyntax) -> ExprSyntax? {
        if let node = expression.as(TryExprSyntax.self) { return node.expression }
        if let node = expression.as(AwaitExprSyntax.self) { return node.expression }
        if let node = expression.as(ForceUnwrapExprSyntax.self) { return node.expression }
        if let node = expression.as(OptionalChainingExprSyntax.self) { return node.expression }
        if let node = expression.as(AsExprSyntax.self) { return node.expression }
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let only = tuple.elements.first, only.label == nil {
            return only.expression
        }
        if let sequence = expression.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            if elements.count == 3, elements[1].is(UnresolvedAsExprSyntax.self) {
                return elements[0]
            }
        }
        return nil
    }

    /// The value-carrying parts of an operator expression, ternary or collection literal.
    private static func combinedParts(_ expression: ExprSyntax) -> [ExprSyntax]? {
        if let sequence = expression.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            if let index = elements.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }),
               let ternary = elements[index].as(UnresolvedTernaryExprSyntax.self) {
                // The condition chooses between the branches; it is not part of the value.
                return [ternary.thenExpression] + elements[(index + 1)...].filter(isOperand)
            }
            return elements.filter(isOperand)
        }
        if let ternary = expression.as(TernaryExprSyntax.self) {
            return [ternary.thenExpression, ternary.elseExpression]
        }
        if let infix = expression.as(InfixOperatorExprSyntax.self) {
            return [infix.leftOperand, infix.rightOperand]
        }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self) {
            return [prefix.expression]
        }
        if let array = expression.as(ArrayExprSyntax.self) {
            return array.elements.map(\.expression)
        }
        if let dictionary = expression.as(DictionaryExprSyntax.self),
           case .elements(let elements) = dictionary.content {
            return elements.map(\.value)
        }
        if let tuple = expression.as(TupleExprSyntax.self) {
            return tuple.elements.map(\.expression)
        }
        return nil
    }

    private static func isOperand(_ element: ExprSyntax) -> Bool {
        !(element.is(BinaryOperatorExprSyntax.self) || element.is(UnresolvedAsExprSyntax.self)
          || element.is(UnresolvedIsExprSyntax.self) || element.is(TypeExprSyntax.self)
          || element.is(AssignmentExprSyntax.self) || element.is(UnresolvedTernaryExprSyntax.self))
    }

    private static func isLiteral(_ expression: ExprSyntax) -> Bool {
        expression.is(IntegerLiteralExprSyntax.self) || expression.is(FloatLiteralExprSyntax.self)
            || expression.is(BooleanLiteralExprSyntax.self) || expression.is(NilLiteralExprSyntax.self)
            || expression.is(RegexLiteralExprSyntax.self)
    }

    private static func arguments(_ list: LabeledExprListSyntax, depth: Int) -> [ExternalInput.Argument] {
        list.map { ExternalInput.Argument(label: $0.label?.text, value: describe($0.expression, depth: depth)) }
    }

    // MARK: - The scope around an expression

    /// The model's scope at `node`.
    public func scope(at node: some SyntaxProtocol) -> ExternalInput.Scope {
        let syntax = Syntax(node)
        let region = Self.region(of: syntax)
        var parameters = region.function.map(Self.parameters(of:)) ?? []
        for closure in region.closures {
            parameters += Self.parameters(of: closure)
        }
        return ExternalInput.Scope(
            bindings: Self.functionBindings(in: region.body).described(before: syntax),
            parameters: parameters,
            commandLineProperties: Self.enclosingTypeName(of: syntax).flatMap { commandLineProperties[$0] } ?? [],
            imports: imports)
    }

    /// Every binding of the function `node` is in, with the syntax each was bound to.
    ///
    /// ``scope(at:)`` describes each initialiser as an `ExternalInput/Expression`, which has no
    /// position and no literal text. A rule that must point at the initialiser, or read the
    /// literal in it, asks here instead. It is the same collection — `scope(at:)` is built from
    /// it — so "in scope" has one definition.
    ///
    /// Collected once for the whole function and then asked by name and point, so a rule that
    /// asks about every call in a function does not walk the function once per question. Hold
    /// the result and key it by ``FunctionBindings/function``.
    public static func bindingSites(at node: some SyntaxProtocol) -> FunctionBindings {
        functionBindings(in: region(of: Syntax(node)).body)
    }

    static func functionBindings(in body: Syntax) -> FunctionBindings {
        let collector = BindingCollector(in: body)
        collector.walk(body)
        return FunctionBindings(function: body.id, sites: collector.sites)
    }

    /// The subtree whose bindings are in scope at `node`: its function, failing that the
    /// outermost closure around it, failing that the file.
    public static func functionBody(of node: some SyntaxProtocol) -> Syntax {
        region(of: Syntax(node)).body
    }

    /// The function declaration `node` is in, when it is in one.
    public static func enclosingFunction(of node: some SyntaxProtocol) -> Syntax? {
        region(of: Syntax(node)).function
    }

    /// The name of the type, or extended type, `node` is declared in.
    public static func enclosingType(of node: some SyntaxProtocol) -> String? {
        enclosingTypeName(of: Syntax(node))
    }

    /// The function a node is in, the closures between it and the node (outermost first), and
    /// the subtree whose bindings are in scope.
    struct Region {
        var function: Syntax?
        var closures: [ClosureExprSyntax]
        var body: Syntax
    }

    static func region(of node: Syntax) -> Region {
        var closures: [ClosureExprSyntax] = []
        var cursor = node.parent
        while let current = cursor {
            if isFunction(current) {
                return Region(function: current, closures: closures.reversed(), body: current)
            }
            if let closure = current.as(ClosureExprSyntax.self) {
                closures.append(closure)
            }
            cursor = current.parent
        }
        let outermost = closures.last.map(Syntax.init)
        return Region(function: nil, closures: closures.reversed(), body: outermost ?? node.root)
    }

    static func isFunction(_ node: Syntax) -> Bool {
        node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self)
            || node.is(AccessorDeclSyntax.self) || node.is(SubscriptDeclSyntax.self)
            || node.is(DeinitializerDeclSyntax.self) || node.is(AccessorBlockSyntax.self)
    }

    private static func parameters(of function: Syntax) -> [ExternalInput.Parameter] {
        let list: FunctionParameterListSyntax?
        if let decl = function.as(FunctionDeclSyntax.self) {
            list = decl.signature.parameterClause.parameters
        } else if let decl = function.as(InitializerDeclSyntax.self) {
            list = decl.signature.parameterClause.parameters
        } else if let decl = function.as(SubscriptDeclSyntax.self) {
            list = decl.parameterClause.parameters
        } else {
            list = nil
        }
        return (list ?? []).enumerated().map { index, parameter in
            ExternalInput.Parameter(
                name: (parameter.secondName ?? parameter.firstName).text,
                type: parameter.type.trimmedDescription,
                index: index)
        }
    }

    private static func parameters(of closure: ClosureExprSyntax) -> [ExternalInput.Parameter] {
        switch closure.signature?.parameterClause {
        case .simpleInput(let names)?:
            return names.enumerated().map { ExternalInput.Parameter(name: $1.name.text, type: nil, index: $0) }
        case .parameterClause(let clause)?:
            return clause.parameters.enumerated().map { index, parameter in
                ExternalInput.Parameter(
                    name: (parameter.secondName ?? parameter.firstName).text,
                    type: parameter.type?.trimmedDescription,
                    index: index)
            }
        case nil:
            return []
        }
    }

    static func enclosingTypeName(of node: Syntax) -> String? {
        var cursor = node.parent
        while let current = cursor {
            if let name = FileFacts.typeName(of: current) { return name }
            cursor = current.parent
        }
        return nil
    }
}

// MARK: - File-wide facts

/// Imports, `Content` conformances and ArgumentParser properties.
final class FileFacts: SyntaxVisitor {
    var imports: Set<String> = []
    var contentTypes: Set<String> = []
    var commandLineProperties: [String: Set<String>] = [:]

    static let argumentAttributes: Set<String> = ["Argument", "Option", "Flag", "OptionGroup"]

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let module = node.path.first?.name.text { imports.insert(module) }
        return .skipChildren
    }

    override func visit(_ node: InheritanceClauseSyntax) -> SyntaxVisitorContinueKind {
        let conformsToContent = node.inheritedTypes.contains {
            let name = $0.type.trimmedDescription
            return name == "Content" || name == "Vapor.Content"
        }
        if conformsToContent, let owner = node.parent, let name = Self.typeName(of: owner) {
            contentTypes.insert(name)
        }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isArgument = node.attributes.contains {
            guard let attribute = $0.as(AttributeSyntax.self) else { return false }
            return Self.argumentAttributes.contains(attribute.attributeName.trimmedDescription)
        }
        guard isArgument, let owner = ExternalInputFile.enclosingTypeName(of: Syntax(node)) else {
            return .visitChildren
        }
        for binding in node.bindings {
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                commandLineProperties[owner, default: []].insert(pattern.identifier.text)
            }
        }
        return .visitChildren
    }

    /// The name a type declaration or extension declares or extends.
    static func typeName(of node: Syntax) -> String? {
        if let decl = node.as(StructDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ClassDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(EnumDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ActorDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ExtensionDeclSyntax.self) { return decl.extendedType.trimmedDescription }
        return nil
    }
}

// MARK: - Bindings of a function

/// One binding in a function: a name, what it was bound to, and where.
public struct BindingSite {
    /// The name bound.
    public let name: String
    /// The initialiser — or, for a `for` loop, the sequence iterated.
    public let value: ExprSyntax
    /// Whether the name is an element of `value` (`for name in value`) rather than `value` itself.
    public let isIteration: Bool
    /// Where the binding starts.
    let site: AbsolutePosition

    /// Whether this binding is in scope at `point`: declared earlier, and `point` is not inside
    /// its own initialiser.
    func isInScope(at point: Syntax) -> Bool {
        site < point.position
            && !(value.position <= point.position && point.endPosition <= value.endPosition)
    }
}

/// Every binding in one function, in source order — see ``ExternalInputFile/bindingSites(at:)``.
public struct FunctionBindings {
    /// The subtree the bindings were collected from.
    public let function: SyntaxIdentifier
    /// Every binding, in source order.
    public let sites: [BindingSite]
    private let byName: [String: [Int]]

    init(function: SyntaxIdentifier, sites: [BindingSite]) {
        self.function = function
        self.sites = sites
        var index: [String: [Int]] = [:]
        for (offset, site) in sites.enumerated() {
            index[site.name, default: []].append(offset)
        }
        self.byName = index
    }

    /// The latest binding of `name` in scope at `point`.
    public func binding(of name: String, before point: some SyntaxProtocol) -> BindingSite? {
        let syntax = Syntax(point)
        guard let candidates = byName[name] else { return nil }
        for offset in candidates.reversed() where sites[offset].isInScope(at: syntax) {
            return sites[offset]
        }
        return nil
    }

    /// The model's bindings at `point`: the latest per name, described.
    func described(before point: Syntax) -> [String: ExternalInput.Expression] {
        var bindings: [String: ExternalInput.Expression] = [:]
        for site in sites where site.isInScope(at: point) {
            let value = ExternalInputFile.describe(site.value)
            bindings[site.name] = site.isIteration ? .subscripted(value, []) : value
        }
        return bindings
    }
}

/// Every binding in a function, in source order.
final class BindingCollector: SyntaxVisitor {
    private let root: SyntaxIdentifier
    private(set) var sites: [BindingSite] = []

    init(in root: Syntax) {
        self.root = root.id
        super.init(viewMode: .sourceAccurate)
    }

    private func bind(_ pattern: some SyntaxProtocol, to value: ExprSyntax, at site: some SyntaxProtocol, iterating: Bool = false) {
        let names = PatternNames(viewMode: .sourceAccurate)
        names.walk(pattern)
        for name in names.names {
            sites.append(BindingSite(name: name, value: value, isIteration: iterating, site: site.position))
        }
    }

    // A nested function is another function, with its own bindings. The region's own
    // function is the root of the walk and is entered.
    private func enter(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        node.id == root ? .visitChildren : .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let value = node.initializer?.value {
            bind(node.pattern, to: value, at: node)
        }
        return .visitChildren
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if let value = node.initializer?.value {
            bind(node.pattern, to: value, at: node)
        }
        return .visitChildren
    }

    override func visit(_ node: MatchingPatternConditionSyntax) -> SyntaxVisitorContinueKind {
        bind(node.pattern, to: node.initializer.value, at: node)
        return .visitChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        bind(node.pattern, to: node.sequence, at: node, iterating: true)
        return .visitChildren
    }
}

/// The names a pattern binds: `x`, `(a, b)`, `.text(let p)`, `let .some(x)`.
private final class PatternNames: SyntaxVisitor {
    private(set) var names: [String] = []

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.append(node.identifier.text)
        return .skipChildren
    }
}
