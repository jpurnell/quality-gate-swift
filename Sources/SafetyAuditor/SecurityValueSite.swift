import QualityGateCore
import SwiftSyntax

/// Reads a `SecurityContext.Site` off the syntax tree: which value an expression is part of,
/// and where that value goes.
///
/// `SecurityContext` answers *is this site a security context* from plain facts; this type
/// gathers the facts. Both the `security.*` randomness rules and `stochastic-*` (which stands
/// down where those rules own the line, `ASeedIsNotASecret.md` §3.6) call it, so the two
/// checkers read one definition of "the value" and cannot both claim a line or both miss it.
///
/// ## The value, not its neighbours
///
/// Starting from an expression, the walk climbs while the parent *is still the same value*,
/// converted (§3.1):
///
/// - a conversion: an unlabelled argument to a type's initialiser (`String(…)`, `UInt8(…)`), or
///   one labelled `truncatingIfNeeded:`, `describing:`, `clamping:`, `bitPattern:`, `exactly:`;
/// - a member that re-expresses its base — `.uuidString`, `.description`, `.base64EncodedString()`,
///   `.hexEncoded()`, `.timeIntervalSince1970`, `.nextInt()`, `.map { … }` (see ``peelMembers``);
/// - string interpolation, arithmetic and concatenation, parentheses, `try`, `await`, `!`;
/// - the single expression of a closure passed to `map` / `compactMap` / `flatMap`;
/// - a dictionary literal's value.
///
/// It stops at anything else. In particular a **labelled argument to some other call** is that
/// call's business: `issue(name: name, now: Date())` makes `Date()` the `now:` argument, not
/// the value of the `let` that receives the call's result.
///
/// ## Where the value goes
///
/// The top of the climb is the value. Its destination is the binding it initialises or is
/// assigned to, the label it is passed under, the function it is returned from (explicitly or
/// as a single-expression body), or the value argument of a header, cookie or query sink.
///
/// ## One local at a time
///
/// A credential is rarely made in one expression. `let bytes = …; return bytes.hexEncoded()` puts
/// the draw in a local named for nothing and the security name on the function. So when a value
/// initialises a **local** whose own name is not a context, each later reference to that local
/// in the same body is followed, a bounded number of hops, and the first that reaches a context
/// answers. A generator passed as `using: &g` is followed into the call it feeds, which is how
/// `var g = SystemRandomNumberGenerator()` is known to be making a token.
///
/// ```swift
/// import SwiftParser
/// import SwiftSyntax
///
/// let tree = Parser.parse(source: "let token = String(drand48())")
/// for name in tree.tokens(viewMode: .sourceAccurate) where name.text == "drand48" {
///     // From the `drand48` reference: through the call and `String(…)` to `let token`.
///     if let reference = name.parent, let resolution = SecurityValueSite.resolve(reference) {
///         print(resolution.verdict)   // .named(term: "token")
///         print(resolution.via)       // []
///     }
/// }
/// ```
public enum SecurityValueSite {

    /// A value found to be in a security context.
    public struct Resolution {
        /// Why the destination is a security context.
        public let verdict: SecurityContext.Verdict
        /// The facts the verdict was reached from.
        public let site: SecurityContext.Site
        /// The value whose destination is ``site``, after any hops through locals.
        public let root: Syntax
        /// The locals the value passed through on its way to ``root``, in order.
        public let via: [String]
    }

    /// Members that re-express their base: the value of `x.member` is still `x`'s value.
    public static let peelMembers: Set<String> = [
        "description", "debugDescription", "uuidString", "base64EncodedString", "base64EncodedData",
        "base64URLEncodedString", "hexString", "hexEncoded", "hexEncodedString", "hexDigest",
        "timeIntervalSince1970", "timeIntervalSinceReferenceDate", "utf8", "lowercased", "uppercased",
        "rawValue", "map", "compactMap", "flatMap", "joined", "sharedRandom", "nextInt", "nextUniform",
        "nextBool", "next", "uptimeNanoseconds", "magnitude", "bigEndian", "littleEndian", "data",
        "string", "stringValue", "intValue", "uint64Value", "doubleValue",
    ]

    /// Argument labels under which a type's initialiser converts rather than configures.
    public static let conversionLabels: Set<String> = [
        "truncatingIfNeeded", "describing", "clamping", "bitPattern", "exactly",
    ]

    /// Members whose closure's result is the value: `(0..<16).map { _ in draw() }`.
    static let mapMembers: Set<String> = ["map", "compactMap", "flatMap"]

    /// How many locals a value may pass through before the walk gives up.
    public static let maximumHops = 3

    // MARK: - Resolution

    /// The security context `node`'s value ends up in, or `nil` when it reaches none.
    ///
    /// - Parameters:
    ///   - node: Any expression that is, or is part of, the value.
    ///   - hops: How many locals may still be followed.
    public static func resolve(_ node: some SyntaxProtocol, hops: Int = maximumHops) -> Resolution? {
        let root = valueRoot(of: Syntax(node))
        guard let destination = destination(of: root) else { return nil }
        let names = enclosingNames(of: root)
        let site = SecurityContext.Site(
            destination: destination, enclosingFunctions: names.functions, enclosingTypes: names.types)
        if let verdict = SecurityContext.evaluate(site) {
            return Resolution(verdict: verdict, site: site, root: root, via: [])
        }
        guard hops > 0, case .binding(let name) = destination, isLocalDeclaration(root),
              let scope = enclosingScope(of: root) else { return nil }
        for reference in references(to: name, in: scope, after: root.endPosition) {
            let next = generatorCall(fedBy: reference) ?? Syntax(reference)
            if let found = resolve(next, hops: hops - 1) {
                return Resolution(verdict: found.verdict, site: found.site, root: found.root, via: [name] + found.via)
            }
        }
        return nil
    }

    /// The top of the climb from `node`: the whole value it is part of.
    public static func valueRoot(of node: Syntax) -> Syntax {
        var current = node
        // Bounded: each step moves to a strict ancestor, and no expression is this deep.
        for _ in 0..<64 {
            guard let parent = valueParent(of: current) else { return current }
            current = parent
        }
        return current
    }

    /// The enclosing expression when it is still `node`'s value, converted; otherwise `nil`.
    static func valueParent(of node: Syntax) -> Syntax? {
        guard let parent = node.parent else { return nil }
        if parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self)
            || parent.is(ForceUnwrapExprSyntax.self) || parent.is(PrefixOperatorExprSyntax.self) {
            return parent
        }
        if let call = parent.as(FunctionCallExprSyntax.self) {
            return call.calledExpression.id == node.id ? parent : nil
        }
        if let member = parent.as(MemberAccessExprSyntax.self) {
            guard member.base?.id == node.id, peelMembers.contains(member.declName.baseName.text) else { return nil }
            if let call = member.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == member.id {
                return Syntax(call)
            }
            return parent
        }
        if let labeled = parent.as(LabeledExprSyntax.self) {
            return argumentParent(labeled)
        }
        if let list = parent.as(ExprListSyntax.self), let sequence = list.parent?.as(SequenceExprSyntax.self) {
            return isArithmetic(sequence) ? Syntax(sequence) : nil
        }
        if let item = parent.as(CodeBlockItemSyntax.self), let items = item.parent?.as(CodeBlockItemListSyntax.self),
           items.count == 1, let closure = items.parent?.as(ClosureExprSyntax.self), let call = mapCall(of: closure) {
            return Syntax(call)
        }
        if let element = parent.as(DictionaryElementSyntax.self), element.value.id == node.id,
           let dictionary = element.parent?.parent, dictionary.is(DictionaryExprSyntax.self) {
            return dictionary
        }
        return nil
    }

    /// A tuple, interpolation or conversion argument climbs to its expression; anything else stops.
    private static func argumentParent(_ labeled: LabeledExprSyntax) -> Syntax? {
        guard let list = labeled.parent?.as(LabeledExprListSyntax.self) else { return nil }
        if let tuple = list.parent?.as(TupleExprSyntax.self) {
            return list.count == 1 && labeled.label == nil ? Syntax(tuple) : nil
        }
        if let segment = list.parent?.as(ExpressionSegmentSyntax.self) {
            guard let literal = segment.parent?.parent, literal.is(StringLiteralExprSyntax.self) else { return nil }
            return literal
        }
        if let call = list.parent?.as(FunctionCallExprSyntax.self), isConversion(call),
           labeled.label.map({ conversionLabels.contains($0.text) }) ?? true {
            return Syntax(call)
        }
        return nil
    }

    // MARK: - Destination

    /// Where the value `root` goes, if it goes anywhere with a name.
    static func destination(of root: Syntax) -> SecurityContext.Destination? {
        guard let parent = root.parent else { return nil }
        if let clause = parent.as(InitializerClauseSyntax.self),
           let binding = clause.parent?.as(PatternBindingSyntax.self),
           let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
            return .binding(name: pattern.identifier.text)
        }
        // A parameter's default value is the value of the parameter, by its local name.
        if let clause = parent.as(InitializerClauseSyntax.self),
           let parameter = clause.parent?.as(FunctionParameterSyntax.self) {
            return .binding(name: (parameter.secondName ?? parameter.firstName).text)
        }
        if let list = parent.as(ExprListSyntax.self), let sequence = list.parent?.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            guard elements.count >= 3, elements[1].is(AssignmentExprSyntax.self),
                  let index = elements.firstIndex(where: { $0.id == root.id }), index >= 2,
                  let name = terminalName(of: elements[0]) else { return nil }
            return .binding(name: name)
        }
        if let labeled = parent.as(LabeledExprSyntax.self) {
            return argumentDestination(labeled)
        }
        if parent.is(ReturnStmtSyntax.self) {
            return returnDestination(from: parent)
        }
        if let item = parent.as(CodeBlockItemSyntax.self), let items = item.parent?.as(CodeBlockItemListSyntax.self),
           items.count == 1 {
            return implicitReturnDestination(of: items)
        }
        return nil
    }

    private static func argumentDestination(_ labeled: LabeledExprSyntax) -> SecurityContext.Destination? {
        guard let list = labeled.parent?.as(LabeledExprListSyntax.self),
              let call = list.parent?.as(FunctionCallExprSyntax.self) else { return nil }
        let arguments = Array(list)
        if let callee = terminalName(of: call.calledExpression),
           let sink = SecurityContext.sink(callee: callee, argumentLabels: arguments.map { $0.label?.text }),
           arguments.indices.contains(sink.valueArgumentIndex),
           arguments[sink.valueArgumentIndex].id == labeled.id {
            return .sink(sink.kind)
        }
        return labeled.label.map { .argument(label: $0.text) }
    }

    /// `return V`: from the innermost function, or a computed property's getter. A closure's
    /// `return` leaves the closure, not the function, so it has no destination here.
    private static func returnDestination(from node: Syntax) -> SecurityContext.Destination? {
        var current = node.parent
        while let candidate = current {
            if candidate.is(ClosureExprSyntax.self) || candidate.is(InitializerDeclSyntax.self) { return nil }
            if let function = candidate.as(FunctionDeclSyntax.self) { return .returned(fromFunction: function.name.text) }
            if let binding = candidate.as(PatternBindingSyntax.self),
               let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                return .binding(name: pattern.identifier.text)
            }
            current = candidate.parent
        }
        return nil
    }

    /// A single-expression body: a function's implicit return, or a getter's.
    private static func implicitReturnDestination(of items: CodeBlockItemListSyntax) -> SecurityContext.Destination? {
        guard let owner = items.parent else { return nil }
        if owner.is(AccessorBlockSyntax.self) { return returnDestination(from: owner) }
        guard owner.is(CodeBlockSyntax.self), let declaration = owner.parent else { return nil }
        if let function = declaration.as(FunctionDeclSyntax.self) { return .returned(fromFunction: function.name.text) }
        if declaration.is(AccessorDeclSyntax.self) { return returnDestination(from: declaration) }
        return nil
    }

    // MARK: - Enclosing names

    /// The lexically enclosing function and type names, outermost first.
    static func enclosingNames(of node: Syntax) -> (functions: [String], types: [String]) {
        var functions: [String] = []
        var types: [String] = []
        var current = node.parent
        while let candidate = current {
            if let function = candidate.as(FunctionDeclSyntax.self) { functions.append(function.name.text) }
            if candidate.is(InitializerDeclSyntax.self) { functions.append("init") }
            if let name = typeName(of: candidate) { types.append(name) }
            current = candidate.parent
        }
        return (functions.reversed(), types.reversed())
    }

    /// The name a type declaration declares, or an extension extends.
    static func typeName(of node: Syntax) -> String? {
        if let declaration = node.as(StructDeclSyntax.self) { return declaration.name.text }
        if let declaration = node.as(ClassDeclSyntax.self) { return declaration.name.text }
        if let declaration = node.as(EnumDeclSyntax.self) { return declaration.name.text }
        if let declaration = node.as(ActorDeclSyntax.self) { return declaration.name.text }
        if let declaration = node.as(ProtocolDeclSyntax.self) { return declaration.name.text }
        if let declaration = node.as(ExtensionDeclSyntax.self) { return declaration.extendedType.trimmedDescription }
        return nil
    }

    // MARK: - Top-down, for rules that ask what a value is made of

    /// The parts of the value at `root`: `[root]`, or for `x = a + b` the operands after `=`.
    static func valueParts(of root: Syntax) -> [Syntax] {
        guard let list = root.parent?.as(ExprListSyntax.self), let sequence = list.parent?.as(SequenceExprSyntax.self) else {
            return [root]
        }
        let elements = Array(sequence.elements)
        guard elements.count >= 3, elements[1].is(AssignmentExprSyntax.self) else { return [root] }
        return operands(of: Array(elements.dropFirst(2))).map(Syntax.init)
    }

    /// The operands of `a op b op c` that make the value. For a chain of `??` that is the last
    /// one alone: `input ?? UUID().uuidString` is a UUID whenever it is not the caller's input,
    /// and the caller's input is the caller's business.
    static func operands(of elements: [ExprSyntax]) -> [ExprSyntax] {
        let operators = elements.compactMap { $0.as(BinaryOperatorExprSyntax.self) }
        let values = elements.filter { !$0.is(BinaryOperatorExprSyntax.self) }
        if !operators.isEmpty, operators.allSatisfy({ $0.operator.text == "??" }), let last = values.last {
            return [last]
        }
        return values
    }

    /// The expressions a value is made of, descending through the same conversions
    /// ``valueParent(of:)`` climbs, and through locals initialised in the same body.
    ///
    /// - Parameters:
    ///   - node: The value, or part of it.
    ///   - depth: How many locals may still be followed.
    ///   - isLeaf: Stops the descent: a source the caller recognises.
    static func leaves(of node: Syntax, depth: Int = maximumHops, isLeaf: (Syntax) -> Bool) -> [Syntax] {
        if isLeaf(node) { return [node] }
        func recurse(_ child: Syntax) -> [Syntax] { leaves(of: child, depth: depth, isLeaf: isLeaf) }
        if let expression = node.as(TryExprSyntax.self) { return recurse(Syntax(expression.expression)) }
        if let expression = node.as(AwaitExprSyntax.self) { return recurse(Syntax(expression.expression)) }
        if let expression = node.as(ForceUnwrapExprSyntax.self) { return recurse(Syntax(expression.expression)) }
        if let expression = node.as(PrefixOperatorExprSyntax.self) { return recurse(Syntax(expression.expression)) }
        if let tuple = node.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let only = tuple.elements.first, only.label == nil {
            return recurse(Syntax(only.expression))
        }
        if let literal = node.as(StringLiteralExprSyntax.self) {
            let segments = literal.segments.compactMap { $0.as(ExpressionSegmentSyntax.self) }
            guard !segments.isEmpty else { return [node] }
            return segments.flatMap { $0.expressions.flatMap { recurse(Syntax($0.expression)) } }
        }
        if let sequence = node.as(SequenceExprSyntax.self), isArithmetic(sequence) {
            return operands(of: Array(sequence.elements)).flatMap { recurse(Syntax($0)) }
        }
        if let call = node.as(FunctionCallExprSyntax.self) {
            return callLeaves(call, recurse: recurse) ?? [node]
        }
        if let member = node.as(MemberAccessExprSyntax.self), let base = member.base,
           peelMembers.contains(member.declName.baseName.text) {
            return recurse(Syntax(base))
        }
        if let dictionary = node.as(DictionaryExprSyntax.self), case .elements(let elements) = dictionary.content {
            return elements.flatMap { recurse(Syntax($0.value)) }
        }
        if let reference = node.as(DeclReferenceExprSyntax.self), depth > 0,
           let initialiser = localInitialiser(named: reference.baseName.text, before: node) {
            return leaves(of: Syntax(initialiser), depth: depth - 1, isLeaf: isLeaf)
        }
        return [node]
    }

    private static func callLeaves(_ call: FunctionCallExprSyntax, recurse: (Syntax) -> [Syntax]) -> [Syntax]? {
        if isConversion(call) {
            let converted = call.arguments.filter { $0.label.map { conversionLabels.contains($0.text) } ?? true }
            return converted.isEmpty ? nil : converted.flatMap { recurse(Syntax($0.expression)) }
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base,
              peelMembers.contains(member.declName.baseName.text) else { return nil }
        var result = recurse(Syntax(base))
        if mapMembers.contains(member.declName.baseName.text), let body = closureExpression(of: call) {
            result += recurse(body)
        }
        return result
    }

    // MARK: - Locals

    /// The initialiser of the last `let` / `var name = …` declared before `node` in its body.
    public static func localInitialiser(named name: String, before node: Syntax) -> ExprSyntax? {
        var scope = enclosingScope(of: node)
        // A closure sees its function's locals: widen until a declaration is found or the
        // function's own body has been searched.
        while let body = scope {
            if let found = lastInitialiser(named: name, in: body, before: node.position) { return found }
            guard body.is(CodeBlockItemListSyntax.self), body.parent?.is(ClosureExprSyntax.self) == true,
                  let closure = body.parent else { return nil }
            scope = enclosingScope(of: closure)
        }
        return nil
    }

    private static func lastInitialiser(named name: String, in body: Syntax, before position: AbsolutePosition) -> ExprSyntax? {
        var found: ExprSyntax?
        for token in body.tokens(viewMode: .sourceAccurate) where token.position < position {
            guard case .identifier(let text) = token.tokenKind, text == name,
                  let pattern = token.parent?.as(IdentifierPatternSyntax.self),
                  let binding = pattern.parent?.as(PatternBindingSyntax.self),
                  binding.parent?.parent?.is(VariableDeclSyntax.self) == true,
                  let value = binding.initializer?.value else { continue }
            found = value
        }
        return found
    }

    /// The function, initialiser, accessor or closure body that `node` sits in, or the file.
    static func enclosingScope(of node: Syntax) -> Syntax? {
        var current = node.parent
        while let candidate = current {
            if let function = candidate.as(FunctionDeclSyntax.self) { return function.body.map(Syntax.init) }
            if let initialiser = candidate.as(InitializerDeclSyntax.self) { return initialiser.body.map(Syntax.init) }
            if let accessor = candidate.as(AccessorDeclSyntax.self) { return accessor.body.map(Syntax.init) }
            if let closure = candidate.as(ClosureExprSyntax.self) { return Syntax(closure.statements) }
            if candidate.is(MemberBlockSyntax.self) { return nil }
            if candidate.is(SourceFileSyntax.self) { return candidate }
            current = candidate.parent
        }
        return nil
    }

    /// Whether `root` initialises a local — a `let` / `var` in a body, not a stored property.
    private static func isLocalDeclaration(_ root: Syntax) -> Bool {
        guard let declaration = root.parent?.parent?.parent?.parent?.as(VariableDeclSyntax.self) else { return false }
        return declaration.parent?.is(CodeBlockItemSyntax.self) ?? false
    }

    /// Each reference to `name` in `scope` after `position`, in source order.
    private static func references(to name: String, in scope: Syntax, after position: AbsolutePosition) -> [DeclReferenceExprSyntax] {
        scope.tokens(viewMode: .sourceAccurate).compactMap { token in
            guard token.position >= position, case .identifier(let text) = token.tokenKind, text == name,
                  let reference = token.parent?.as(DeclReferenceExprSyntax.self) else { return nil }
            // `x.name` names a member, not this local.
            if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id == reference.id {
                return nil
            }
            return reference
        }
    }

    /// The call `&reference` feeds as its `using:` generator.
    static func generatorCall(fedBy reference: DeclReferenceExprSyntax) -> Syntax? {
        guard let inOut = reference.parent?.as(InOutExprSyntax.self),
              let labeled = inOut.parent?.as(LabeledExprSyntax.self), labeled.label?.text == "using",
              let call = labeled.parent?.parent?.as(FunctionCallExprSyntax.self) else { return nil }
        return Syntax(call)
    }

    // MARK: - Shapes

    /// A type's initialiser: `String(…)`, `[UInt8](…)`, `Array<UInt8>(…)`, `String.init(…)`.
    static func isConversion(_ call: FunctionCallExprSyntax) -> Bool {
        var callee = call.calledExpression
        if let member = callee.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init",
           let base = member.base {
            callee = base
        }
        if let specialised = callee.as(GenericSpecializationExprSyntax.self) { callee = specialised.expression }
        if callee.is(ArrayExprSyntax.self) { return true }
        guard let reference = callee.as(DeclReferenceExprSyntax.self),
              let first = reference.baseName.text.first else { return false }
        return first.isUppercase
    }

    /// `a + b`, `x % n`, `lo ..< hi` — a sequence with an operator and no assignment.
    static func isArithmetic(_ sequence: SequenceExprSyntax) -> Bool {
        !sequence.elements.contains { $0.is(AssignmentExprSyntax.self) }
            && sequence.elements.contains { $0.is(BinaryOperatorExprSyntax.self) }
    }

    /// The `map` call a closure is the transform of.
    private static func mapCall(of closure: ClosureExprSyntax) -> FunctionCallExprSyntax? {
        var call = closure.parent?.as(FunctionCallExprSyntax.self)
        if call?.trailingClosure?.id != closure.id { call = nil }
        if call == nil, let labeled = closure.parent?.as(LabeledExprSyntax.self) {
            call = labeled.parent?.parent?.as(FunctionCallExprSyntax.self)
        }
        guard let found = call, let member = found.calledExpression.as(MemberAccessExprSyntax.self),
              mapMembers.contains(member.declName.baseName.text) else { return nil }
        return found
    }

    /// The single expression of the closure passed to a `map` call.
    private static func closureExpression(of call: FunctionCallExprSyntax) -> Syntax? {
        let closure = call.trailingClosure ?? call.arguments.first?.expression.as(ClosureExprSyntax.self)
        guard let statements = closure?.statements, statements.count == 1,
              let only = statements.first?.item.as(ExprSyntax.self) else { return nil }
        return Syntax(only)
    }

    /// The name an assignment target or callee ends in: `token`, `self.token` → `token`.
    static func terminalName(of expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
        if let member = expression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
        return nil
    }
}
