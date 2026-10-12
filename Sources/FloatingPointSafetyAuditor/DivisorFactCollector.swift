import Foundation
import SwiftSyntax

/// Builds a ``DivisorFactIndex`` from one file, in one walk.
final class DivisorFactCollector: SyntaxVisitor {
    private let conversions: Set<String>
    private let fileEnd: Int

    /// What the walk found.
    private(set) var index = DivisorFactIndex()

    /// Creates a collector.
    /// - Parameters:
    ///   - conversions: Names whose single-argument call is a conversion to a
    ///     floating-point type.
    ///   - fileEnd: The UTF-8 offset of the end of the file.
    init(conversions: Set<String>, fileEnd: Int) {
        self.conversions = conversions
        self.fileEnd = fileEnd
        super.init(viewMode: .sourceAccurate)
    }

    /// Collects the facts one file holds.
    static func collect(from file: SourceFileSyntax, conversions: Set<String>) -> DivisorFactIndex {
        let collector = DivisorFactCollector(conversions: conversions, fileEnd: file.endPosition.utf8Offset)
        collector.walk(file)
        return collector.index
    }

    // MARK: - Positions

    private func offset(of node: some SyntaxProtocol) -> Int {
        node.positionAfterSkippingLeadingTrivia.utf8Offset
    }

    private func region(of node: some SyntaxProtocol) -> DivisorFactIndex.Region {
        DivisorFactIndex.Region(start: offset(of: node), end: node.endPosition.utf8Offset)
    }

    /// From the end of `node` to the end of the block it is a statement of.
    private func regionFollowing(_ node: some SyntaxProtocol) -> DivisorFactIndex.Region {
        DivisorFactIndex.Region(start: node.endPosition.utf8Offset, end: enclosingBlockEnd(of: Syntax(node)))
    }

    private func enclosingBlockEnd(of node: Syntax) -> Int {
        var current = node.parent
        while let candidate = current {
            if candidate.is(CodeBlockItemListSyntax.self) { return candidate.endPosition.utf8Offset }
            current = candidate.parent
        }
        return fileEnd
    }

    private func key(of expr: ExprSyntax) -> String? {
        FallbackSubjectKey.key(of: expr, genericNames: conversions)
    }

    /// Every identifier an expression mentions.
    private func names(in node: some SyntaxProtocol) -> Set<String> {
        var found: Set<String> = []
        for token in node.tokens(viewMode: .sourceAccurate) {
            if case .identifier(let text) = token.tokenKind { found.insert(text) }
        }
        return found
    }

    // MARK: - Types

    private func enterType(named name: String, _ node: some SyntaxProtocol) {
        index.types.append(DivisorFactIndex.TypeRange(name: name, region: region(of: node)))
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(named: node.name.text, node)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(named: node.name.text, node)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(named: node.name.text, node)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(named: node.name.text, node)
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let spelled = node.extendedType.trimmedDescription
        enterType(named: spelled.split(separator: ".").last.map(String.init) ?? spelled, node)
        return .visitChildren
    }

    /// The name of the type whose member block `node` sits directly in.
    private func owningTypeName(of node: Syntax) -> String? {
        guard let item = node.parent?.as(MemberBlockItemSyntax.self),
              let owner = item.parent?.parent?.parent else { return nil }
        if let decl = owner.as(StructDeclSyntax.self) { return decl.name.text }
        if let decl = owner.as(ClassDeclSyntax.self) { return decl.name.text }
        if let decl = owner.as(EnumDeclSyntax.self) { return decl.name.text }
        if let decl = owner.as(ActorDeclSyntax.self) { return decl.name.text }
        if let decl = owner.as(ExtensionDeclSyntax.self) {
            let spelled = decl.extendedType.trimmedDescription
            return spelled.split(separator: ".").last.map(String.init) ?? spelled
        }
        return nil
    }

    // MARK: - Declarations

    private func declare(_ binding: DivisorFactIndex.Binding) {
        index.bindings[binding.name, default: []].append(binding)
        recordRedeclaration(of: binding.name, at: binding.offset)
    }

    private func declareOpaque(_ name: String, at node: some SyntaxProtocol, in region: DivisorFactIndex.Region,
                               typeText: String? = nil, isImmutable: Bool = true) {
        declare(DivisorFactIndex.Binding(
            name: name, region: region, offset: offset(of: node),
            source: .opaque, typeText: typeText, isImmutable: isImmutable))
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isLet = node.bindingSpecifier.tokenKind == .keyword(.let)
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                declareDestructured(binding.pattern, of: node, isLet: isLet)
                continue
            }
            let annotation = binding.typeAnnotation?.type.trimmedDescription
            var source = DivisorFactIndex.Source.opaque
            if isLet, binding.accessorBlock == nil, let initializer = binding.initializer {
                source = .constant(initializer: initializer.value, annotation: annotation)
            }
            place(name: pattern.identifier.text, source: source, typeText: annotation,
                  isLet: isLet, binding: Syntax(binding), declaration: node)
            collectPredicate(named: pattern.identifier.text, binding: binding, declaration: node)
        }
        return .visitChildren
    }

    /// `let (a, b) = …`: both names are declared, and neither value is read.
    private func declareDestructured(_ pattern: PatternSyntax, of declaration: VariableDeclSyntax, isLet: Bool) {
        for token in pattern.tokens(viewMode: .sourceAccurate) {
            guard case .identifier(let name) = token.tokenKind else { continue }
            place(name: name, source: .opaque, typeText: nil, isLet: isLet,
                  binding: Syntax(pattern), declaration: declaration)
        }
    }

    /// Files a declaration as a member, a global or a local, by where it is written.
    private func place(
        name: String,
        source: DivisorFactIndex.Source,
        typeText: String?,
        isLet: Bool,
        binding: Syntax,
        declaration: VariableDeclSyntax
    ) {
        let whole = DivisorFactIndex.Region(start: 0, end: fileEnd)
        if let typeName = owningTypeName(of: Syntax(declaration)) {
            index.members[typeName, default: [:]][name, default: []].append(DivisorFactIndex.Binding(
                name: name, region: whole, offset: offset(of: binding),
                source: source, typeText: typeText, isImmutable: isLet))
            return
        }
        if isAtFileScope(Syntax(declaration)) {
            if index.globals[name] != nil { index.ambiguousGlobals.insert(name) }
            index.globals[name] = DivisorFactIndex.Binding(
                name: name, region: whole, offset: offset(of: binding),
                source: source, typeText: typeText, isImmutable: isLet)
            recordRedeclaration(of: name, at: offset(of: binding))
            return
        }
        // Anywhere else that is not inside a body — a member behind `#if` —
        // the name is declared and its value is not read.
        declare(DivisorFactIndex.Binding(
            name: name,
            region: DivisorFactIndex.Region(
                start: binding.endPosition.utf8Offset,
                end: enclosingBlockEnd(of: Syntax(declaration))),
            offset: offset(of: binding),
            source: isInsideBody(Syntax(declaration)) ? source : .opaque,
            typeText: typeText, isImmutable: isLet))
    }

    /// True when the nearest enclosing statement list is a body, not the file.
    private func isInsideBody(_ node: Syntax) -> Bool {
        var current = node.parent
        while let candidate = current {
            if candidate.is(CodeBlockItemListSyntax.self) {
                return !(candidate.parent?.is(SourceFileSyntax.self) ?? true)
            }
            current = candidate.parent
        }
        return false
    }

    private func isAtFileScope(_ node: Syntax) -> Bool {
        node.parent?.as(CodeBlockItemSyntax.self)?.parent?.parent?.is(SourceFileSyntax.self) ?? false
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        declare(parameters: node.signature.parameterClause.parameters, of: node)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        declare(parameters: node.signature.parameterClause.parameters, of: node)
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        declare(parameters: node.parameterClause.parameters, of: node)
        return .visitChildren
    }

    private func declare(parameters: FunctionParameterListSyntax, of owner: some SyntaxProtocol) {
        for parameter in parameters {
            let name = (parameter.secondName ?? parameter.firstName).text
            guard name != "_" else { continue }
            let written = parameter.type.trimmedDescription
            declareOpaque(name, at: parameter, in: region(of: owner),
                          typeText: FallbackTypes.spelling(of: parameter.type),
                          isImmutable: !written.hasPrefix("inout"))
        }
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        for parameter in FallbackTypes.parameters(of: node.signature) {
            declareOpaque(parameter.name, at: node, in: region(of: node), typeText: parameter.typeText)
        }
        return .visitChildren
    }

    // `if let x`, `guard let x`, `while let x`.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        guard let pattern = node.pattern.as(IdentifierPatternSyntax.self) else { return .visitChildren }
        let isLet = node.bindingSpecifier.tokenKind == .keyword(.let)
        declareOpaque(pattern.identifier.text, at: node, in: reach(ofCondition: Syntax(node)),
                      typeText: node.typeAnnotation?.type.trimmedDescription, isImmutable: isLet)
        return .visitChildren
    }

    /// Where a name bound in a condition is in scope: after a `guard`, to the
    /// end of the block; otherwise to the end of the statement it belongs to.
    private func reach(ofCondition node: Syntax) -> DivisorFactIndex.Region {
        var current = node.parent
        while let candidate = current {
            if let statement = candidate.as(GuardStmtSyntax.self) {
                return DivisorFactIndex.Region(start: node.endPosition.utf8Offset,
                                               end: enclosingBlockEnd(of: Syntax(statement)))
            }
            if candidate.is(IfExprSyntax.self) || candidate.is(WhileStmtSyntax.self) {
                return DivisorFactIndex.Region(start: node.endPosition.utf8Offset,
                                               end: candidate.endPosition.utf8Offset)
            }
            current = candidate.parent
        }
        return DivisorFactIndex.Region(start: node.endPosition.utf8Offset, end: fileEnd)
    }

    // `case .some(let x)`, `catch let e`, `for case let x? in …`.
    override func visit(_ node: ValueBindingPatternSyntax) -> SyntaxVisitorContinueKind {
        let reach = DivisorFactIndex.Region(start: node.endPosition.utf8Offset,
                                            end: enclosingScopeEnd(of: Syntax(node)))
        for token in node.pattern.tokens(viewMode: .sourceAccurate) {
            guard case .identifier(let name) = token.tokenKind else { continue }
            declareOpaque(name, at: node, in: reach, isImmutable: false)
        }
        return .visitChildren
    }

    /// The end of the `case`, `catch`, loop or condition a pattern belongs to.
    private func enclosingScopeEnd(of node: Syntax) -> Int {
        var current = node.parent
        while let candidate = current {
            if candidate.is(SwitchCaseSyntax.self) || candidate.is(CatchClauseSyntax.self)
                || candidate.is(ForStmtSyntax.self) || candidate.is(IfExprSyntax.self)
                || candidate.is(WhileStmtSyntax.self) {
                return candidate.endPosition.utf8Offset
            }
            if candidate.is(GuardStmtSyntax.self) { return enclosingBlockEnd(of: candidate) }
            current = candidate.parent
        }
        return fileEnd
    }

    // MARK: - Loops

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        index.loops.append(region(of: node))
        let body = region(of: node.body)
        let range = Self.range(in: Self.unwrapped(node.sequence))
        declareLoopNames(node.pattern, sequence: node.sequence, lower: range?.lower, body: body)
        if let range, range.upper.count == 1, let upper = range.upper.first, let subject = key(of: upper) {
            add(DivisorFactIndex.Condition(
                key: subject, names: names(in: upper),
                claim: .above(threshold: range.lower, strict: range.isHalfOpen),
                // The range is read once, before the loop. Placing the claim
                // there puts the loop itself after it, so a change to the
                // bound anywhere in the body ends the claim.
                region: body, offset: offset(of: node) - 1))
        }
        return .visitChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        index.loops.append(region(of: node))
        return .visitChildren
    }

    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        index.loops.append(region(of: node))
        return .visitChildren
    }

    private func declareLoopNames(
        _ pattern: PatternSyntax,
        sequence: ExprSyntax,
        lower: [ExprSyntax]?,
        body: DivisorFactIndex.Region
    ) {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            let source = lower.map { DivisorFactIndex.Source.rangeIndex(lower: $0) } ?? .opaque
            declare(DivisorFactIndex.Binding(
                name: identifier.identifier.text, region: body, offset: offset(of: pattern),
                source: source, typeText: nil, isImmutable: true))
            return
        }
        guard let tuple = pattern.as(TuplePatternSyntax.self) else { return }
        for (position, element) in tuple.elements.enumerated() {
            guard let identifier = element.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let isIndex = position == 0 && Self.isEnumerated(sequence)
            declare(DivisorFactIndex.Binding(
                name: identifier.identifier.text, region: body, offset: offset(of: element),
                source: isIndex ? .nonNegative : .opaque, typeText: nil, isImmutable: true))
        }
    }

    /// `xs.enumerated()`.
    private static func isEnumerated(_ sequence: ExprSyntax) -> Bool {
        guard let call = sequence.as(FunctionCallExprSyntax.self), call.arguments.isEmpty,
              let callee = call.calledExpression.as(MemberAccessExprSyntax.self) else { return false }
        return callee.declName.baseName.text == "enumerated"
    }

    /// `e` from `(e)` and from `(e).reversed()`: the same elements.
    private static func unwrapped(_ sequence: ExprSyntax) -> ExprSyntax {
        var current = sequence
        if let call = current.as(FunctionCallExprSyntax.self), call.arguments.isEmpty,
           let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
           callee.declName.baseName.text == "reversed", let base = callee.base {
            current = base
        }
        if let tuple = current.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let only = tuple.elements.first, only.label == nil {
            current = only.expression
        }
        return current
    }

    /// The two sides of `lower..<upper` or `lower...upper`.
    private static func range(in expr: ExprSyntax) -> (lower: [ExprSyntax], upper: [ExprSyntax], isHalfOpen: Bool)? {
        guard let sequence = expr.as(SequenceExprSyntax.self) else { return nil }
        let elements = Array(sequence.elements)
        let operators = elements.indices.filter { position in
            let text = elements[position].as(BinaryOperatorExprSyntax.self)?.operator.text
            return text == "..<" || text == "..."
        }
        guard operators.count == 1, let position = operators.first, position > 0,
              position < elements.count - 1,
              let text = elements[position].as(BinaryOperatorExprSyntax.self)?.operator.text else { return nil }
        return (Array(elements[..<position]), Array(elements[(position + 1)...]), text == "..<")
    }

    // MARK: - Conditions

    private func add(_ condition: DivisorFactIndex.Condition) {
        index.conditions[condition.key, default: []].append(condition)
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        let after = regionFollowing(node)
        for condition in node.conditions {
            guard case .expression(let expr) = condition.condition else { continue }
            ConditionReader(collector: self, region: after).read(expr, holds: true)
        }
        return .visitChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        let then = region(of: node.body)
        for condition in node.conditions {
            guard case .expression(let expr) = condition.condition else { continue }
            ConditionReader(collector: self, region: then).read(expr, holds: true)
        }
        // The opposite holds where the condition failed — which is only
        // knowable when the condition is one expression and not a list.
        guard node.conditions.count == 1, let only = node.conditions.first,
              case .expression(let expr) = only.condition else { return .visitChildren }
        if let elseBody = node.elseBody {
            ConditionReader(collector: self, region: region(of: elseBody)).read(expr, holds: false)
        } else if Self.alwaysLeaves(node.body), !(node.parent?.is(IfExprSyntax.self) ?? false) {
            ConditionReader(collector: self, region: regionFollowing(node)).read(expr, holds: false)
        }
        return .visitChildren
    }

    /// True when control cannot fall out of the bottom of `block`.
    private static func alwaysLeaves(_ block: CodeBlockSyntax) -> Bool {
        guard let last = block.statements.last else { return false }
        if case .stmt(let statement) = last.item {
            return statement.is(ReturnStmtSyntax.self) || statement.is(ThrowStmtSyntax.self)
                || statement.is(ContinueStmtSyntax.self) || statement.is(BreakStmtSyntax.self)
        }
        guard case .expr(let expr) = last.item,
              let call = expr.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) else { return false }
        return callee.baseName.text == "fatalError" || callee.baseName.text == "preconditionFailure"
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        recordAssignments(in: elements)
        for (position, element) in elements.enumerated() {
            guard let ternary = element.as(UnresolvedTernaryExprSyntax.self) else { continue }
            let start = elements[..<position].lastIndex { candidate in
                candidate.is(AssignmentExprSyntax.self) || candidate.is(UnresolvedTernaryExprSyntax.self)
            }.map { $0 + 1 } ?? 0
            let condition = Array(elements[start..<position])
            ConditionReader(collector: self, region: region(of: ternary.thenExpression))
                .read(run: condition, holds: true)
            let otherwise = DivisorFactIndex.Region(start: ternary.endPosition.utf8Offset,
                                                    end: node.endPosition.utf8Offset)
            ConditionReader(collector: self, region: otherwise).read(run: condition, holds: false)
        }
        return .visitChildren
    }

    // MARK: - Changes

    private static let comparisonSpellings: Set<String> = ["==", "!=", "<=", ">=", "===", "!==", "~="]

    private func recordAssignments(in elements: [ExprSyntax]) {
        for (position, element) in elements.enumerated() where position > 0 {
            var assigns = element.is(AssignmentExprSyntax.self)
            if let text = element.as(BinaryOperatorExprSyntax.self)?.operator.text {
                assigns = text.hasSuffix("=") && !Self.comparisonSpellings.contains(text)
            }
            if assigns { recordChange(to: elements[position - 1], at: element) }
        }
    }

    /// A new declaration of a name ends what was claimed of the old one.
    private func recordRedeclaration(of name: String, at offset: Int) {
        index.changes[name, default: []].append(DivisorFactIndex.Change(
            offset: offset, path: [name], method: nil, isOnElement: false, deferredWithin: nil))
    }

    private func recordChange(to target: ExprSyntax, method: String? = nil, at node: some SyntaxProtocol) {
        let path = Self.path(of: target).names
        guard let owner = path.first else { return }
        index.changes[owner, default: []].append(DivisorFactIndex.Change(
            offset: offset(of: node), path: path, method: method,
            isOnElement: target.is(SubscriptCallExprSyntax.self),
            deferredWithin: isCaptured(owner, at: Syntax(node)) ? body(enclosing: Syntax(node)) : nil))
    }

    /// True when `name` is declared outside the closure or local function
    /// that `node` is written in.
    ///
    /// `let reset = { n = 0 }` can be written above a guard on `n` and run
    /// below it, so where the assignment sits says nothing about when it happens.
    private func isCaptured(_ name: String, at node: Syntax) -> Bool {
        guard let start = deferredBodyStart(enclosing: node) else { return false }
        guard let declared = index.binding(name, at: offset(of: node)) else { return true }
        return declared.region.start < start
    }

    /// The outermost function, accessor or member that `node` is written in:
    /// the body a closure inside it could be called from. Top-level code is
    /// one body, the file.
    private func body(enclosing node: Syntax) -> DivisorFactIndex.Region {
        var outermost: Syntax?
        var current = node.parent
        while let candidate = current {
            if candidate.is(FunctionDeclSyntax.self) || candidate.is(InitializerDeclSyntax.self)
                || candidate.is(SubscriptDeclSyntax.self) || candidate.is(AccessorBlockSyntax.self)
                || candidate.is(MemberBlockItemSyntax.self) {
                outermost = candidate
            }
            current = candidate.parent
        }
        return outermost.map { region(of: $0) } ?? DivisorFactIndex.Region(start: 0, end: fileEnd)
    }

    /// Where the nearest enclosing closure or local function begins.
    private func deferredBodyStart(enclosing node: Syntax) -> Int? {
        var current = node.parent
        while let candidate = current {
            if candidate.is(ClosureExprSyntax.self) { return offset(of: candidate) }
            if candidate.is(FunctionDeclSyntax.self), let item = candidate.parent?.as(CodeBlockItemSyntax.self),
               !(item.parent?.parent?.is(SourceFileSyntax.self) ?? true) {
                return offset(of: candidate)
            }
            current = candidate.parent
        }
        return nil
    }

    override func visit(_ node: InOutExprSyntax) -> SyntaxVisitorContinueKind {
        recordChange(to: node.expression, at: node)
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression.as(MemberAccessExprSyntax.self), let base = callee.base {
            recordChange(to: base, method: callee.declName.baseName.text, at: node)
        }
        return .visitChildren
    }

    /// The member path an expression names, and whether that is all of it.
    /// `self.x.y` is `x.y`; `xs[i].y` is `xs`, and not all of it.
    private static func path(of expr: ExprSyntax, depth: Int = 0) -> (names: [String], isWhole: Bool) {
        guard depth < 12 else { return ([], false) }
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return ([reference.baseName.text], true)
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            if base.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
                return ([member.declName.baseName.text], true)
            }
            let owner = path(of: base, depth: depth + 1)
            guard owner.isWhole, !owner.names.isEmpty else { return (owner.names, false) }
            return (owner.names + [member.declName.baseName.text], true)
        }
        if let call = expr.as(SubscriptCallExprSyntax.self) {
            return (path(of: call.calledExpression, depth: depth + 1).names, false)
        }
        if let unwrapped = expr.as(ForceUnwrapExprSyntax.self) {
            return path(of: unwrapped.expression, depth: depth + 1)
        }
        if let chained = expr.as(OptionalChainingExprSyntax.self) {
            return path(of: chained.expression, depth: depth + 1)
        }
        return ([], false)
    }

    // MARK: - Predicates

    /// Records what `var name: Bool { guard … else { return false }; … }`
    /// guarantees when it returns true: every condition of its leading guards.
    private func collectPredicate(named name: String, binding: PatternBindingSyntax, declaration: VariableDeclSyntax) {
        guard let typeName = owningTypeName(of: Syntax(declaration)),
              binding.typeAnnotation?.type.trimmedDescription == "Bool",
              let statements = Self.getterStatements(of: binding) else { return }
        let reader = ConditionReader(
            collector: self, region: DivisorFactIndex.Region(start: 0, end: fileEnd), recordsPredicateUses: false)
        var guaranteed: [DivisorFactIndex.Condition] = []
        for statement in statements {
            guard case .stmt(let item) = statement.item,
                  let guardStatement = item.as(GuardStmtSyntax.self),
                  Self.returnsFalse(guardStatement.body) else { break }
            for condition in guardStatement.conditions {
                guard case .expression(let expr) = condition.condition else { continue }
                guaranteed.append(contentsOf: reader.conditions(in: expr, holds: true))
            }
        }
        guard !guaranteed.isEmpty else { return }
        index.predicates[typeName, default: [:]][name, default: []].append(contentsOf: guaranteed)
    }

    private static func getterStatements(of binding: PatternBindingSyntax) -> CodeBlockItemListSyntax? {
        guard let block = binding.accessorBlock else { return nil }
        switch block.accessors {
        case .getter(let statements):
            return statements
        case .accessors(let accessors):
            return accessors.first { $0.accessorSpecifier.tokenKind == .keyword(.get) }?.body?.statements
        }
    }

    private static func returnsFalse(_ block: CodeBlockSyntax) -> Bool {
        guard block.statements.count == 1, let only = block.statements.first,
              case .stmt(let statement) = only.item,
              let returned = statement.as(ReturnStmtSyntax.self)?.expression?.as(BooleanLiteralExprSyntax.self) else {
            return false
        }
        return returned.literal.tokenKind == .keyword(.false)
    }

    // MARK: - Reader support

    /// What ``ConditionReader`` needs from the collector.
    fileprivate func subjectKey(of expr: ExprSyntax) -> (key: String, names: Set<String>)? {
        guard let subject = key(of: expr) else { return nil }
        return (subject, names(in: expr))
    }

    fileprivate func record(_ conditions: [DivisorFactIndex.Condition]) {
        conditions.forEach(add)
    }

    fileprivate func record(_ use: DivisorFactIndex.PredicateUse) {
        index.predicateUses.append(use)
    }

    fileprivate func position(of node: some SyntaxProtocol) -> Int {
        offset(of: node)
    }
}

// MARK: - Reading a condition

/// Reads the claims one condition makes, for the region where it holds.
///
/// `holds` is false where the condition is known to have *failed*: the `else`
/// of an `if`, the code after an `if` that always leaves, the second arm of a
/// ternary. There `!(a || b)` gives both `!a` and `!b`, and `!(a && b)` gives
/// nothing.
private struct ConditionReader {
    let collector: DivisorFactCollector
    let region: DivisorFactIndex.Region
    /// False while reading a predicate's own body: what it tests there is not
    /// a guard on the code around it.
    var recordsPredicateUses = true

    private static let comparisons: Set<String> = ["==", "!=", "<", "<=", ">", ">="]
    private static let opposites: [String: String] = [
        "==": "!=", "!=": "==", "<": ">=", "<=": ">", ">": "<=", ">=": "<"
    ]

    /// Records every claim `expr` makes.
    func read(_ expr: ExprSyntax, holds: Bool) {
        collector.record(conditions(in: expr, holds: holds))
    }

    /// Records every claim a run of sequence elements makes.
    func read(run: [ExprSyntax], holds: Bool) {
        collector.record(conditions(inRun: run, holds: holds, depth: 0))
    }

    /// The claims `expr` makes.
    func conditions(in expr: ExprSyntax, holds: Bool, depth: Int = 0) -> [DivisorFactIndex.Condition] {
        guard depth < 8 else { return [] }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let only = tuple.elements.first, only.label == nil {
            return conditions(in: only.expression, holds: holds, depth: depth + 1)
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            return conditions(in: prefix.expression, holds: !holds, depth: depth + 1)
        }
        if let sequence = expr.as(SequenceExprSyntax.self) {
            return conditions(inRun: Array(sequence.elements), holds: holds, depth: depth + 1)
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return conditions(inRun: [infix.leftOperand, infix.operator, infix.rightOperand],
                              holds: holds, depth: depth + 1)
        }
        return atom(expr, holds: holds)
    }

    private func conditions(inRun run: [ExprSyntax], holds: Bool, depth: Int) -> [DivisorFactIndex.Condition] {
        guard depth < 8 else { return [] }
        let alternatives = Self.split(run, on: "||")
        if alternatives.count > 1 {
            // `a || b` holding says nothing of either; failing denies both.
            guard !holds else { return [] }
            return alternatives.flatMap { alternative -> [DivisorFactIndex.Condition] in
                Self.split(alternative, on: "&&").count == 1
                    ? conjunct(alternative, holds: false, depth: depth) : []
            }
        }
        let conjuncts = Self.split(run, on: "&&")
        if holds { return conjuncts.flatMap { conjunct($0, holds: true, depth: depth) } }
        return conjuncts.count == 1 ? conjunct(run, holds: false, depth: depth) : []
    }

    private static func split(_ run: [ExprSyntax], on operatorText: String) -> [[ExprSyntax]] {
        run.split(omittingEmptySubsequences: false) { element in
            element.as(BinaryOperatorExprSyntax.self)?.operator.text == operatorText
        }.map(Array.init)
    }

    private func conjunct(_ run: [ExprSyntax], holds: Bool, depth: Int) -> [DivisorFactIndex.Condition] {
        if run.count == 1, let only = run.first {
            return conditions(in: only, holds: holds, depth: depth + 1)
        }
        let positions = run.indices.filter { position in
            guard let text = run[position].as(BinaryOperatorExprSyntax.self)?.operator.text else { return false }
            return Self.comparisons.contains(text)
        }
        guard positions.count == 1, let position = positions.first,
              let written = run[position].as(BinaryOperatorExprSyntax.self)?.operator.text,
              let text = holds ? written : Self.opposites[written] else { return [] }
        let lhs = Array(run[..<position])
        let rhs = Array(run[(position + 1)...])
        if let literal = Self.booleanLiteral(lhs) ?? Self.booleanLiteral(rhs), text == "==" || text == "!=" {
            let other = Self.booleanLiteral(lhs) == nil ? lhs : rhs
            guard other.count == 1, let only = other.first else { return [] }
            return conditions(in: only, holds: literal == (text == "=="), depth: depth + 1)
        }
        return comparison(lhs, text, rhs, at: run[position])
    }

    private static func booleanLiteral(_ run: [ExprSyntax]) -> Bool? {
        guard run.count == 1, let literal = run.first?.as(BooleanLiteralExprSyntax.self) else { return nil }
        return literal.literal.tokenKind == .keyword(.true)
    }

    private func comparison(
        _ lhs: [ExprSyntax],
        _ text: String,
        _ rhs: [ExprSyntax],
        at node: ExprSyntax
    ) -> [DivisorFactIndex.Condition] {
        switch text {
        case ">": return above(lhs, threshold: rhs, strict: true, at: node)
        case ">=": return above(lhs, threshold: rhs, strict: false, at: node)
        case "<": return above(rhs, threshold: lhs, strict: true, at: node)
        case "<=": return above(rhs, threshold: lhs, strict: false, at: node)
        case "!=": return notZero(lhs, comparedWith: rhs, at: node) + notZero(rhs, comparedWith: lhs, at: node)
        default: return []
        }
    }

    private func above(
        _ subject: [ExprSyntax],
        threshold: [ExprSyntax],
        strict: Bool,
        at node: ExprSyntax
    ) -> [DivisorFactIndex.Condition] {
        guard subject.count == 1, let only = subject.first else { return [] }
        if let inner = Self.magnitudeArgument(of: only) {
            return condition(on: inner, .magnitudeAbove(threshold: threshold, strict: strict), at: node)
        }
        return condition(on: only, .above(threshold: threshold, strict: strict), at: node)
    }

    private func notZero(
        _ subject: [ExprSyntax],
        comparedWith other: [ExprSyntax],
        at node: ExprSyntax
    ) -> [DivisorFactIndex.Condition] {
        guard subject.count == 1, let only = subject.first,
              NumericLiteralFacts.threshold(ofRun: other[...]) == .zero else { return [] }
        return condition(on: Self.magnitudeArgument(of: only) ?? only, .nonZero, at: node)
    }

    private func condition(
        on subject: ExprSyntax,
        _ claim: DivisorFactIndex.Claim,
        at node: some SyntaxProtocol,
        suffix: String = ""
    ) -> [DivisorFactIndex.Condition] {
        guard let named = collector.subjectKey(of: subject) else { return [] }
        return [DivisorFactIndex.Condition(
            key: named.key + suffix, names: named.names, claim: claim,
            region: region, offset: collector.position(of: node))]
    }

    /// A condition that is not a comparison: `xs.isEmpty`, `x.isZero`, or a
    /// Bool the file may say more about.
    private func atom(_ expr: ExprSyntax, holds: Bool) -> [DivisorFactIndex.Condition] {
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            let name = member.declName.baseName.text
            if name == "isEmpty" {
                return holds ? [] : condition(on: base, .atLeastOne, at: expr, suffix: ".count")
            }
            if name == "isZero" {
                return holds ? [] : condition(on: base, .nonZero, at: expr)
            }
            if holds, recordsPredicateUses, let reference = base.as(DeclReferenceExprSyntax.self) {
                collector.record(DivisorFactIndex.PredicateUse(
                    base: reference.baseName.text, name: name,
                    region: region, offset: collector.position(of: expr)))
            }
            return []
        }
        if holds, recordsPredicateUses, let reference = expr.as(DeclReferenceExprSyntax.self) {
            collector.record(DivisorFactIndex.PredicateUse(
                base: nil, name: reference.baseName.text,
                region: region, offset: collector.position(of: expr)))
        }
        return []
    }

    /// `x` from `abs(x)` or `x.magnitude`.
    private static func magnitudeArgument(of expr: ExprSyntax) -> ExprSyntax? {
        if let call = expr.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
           callee.baseName.text == "abs", call.arguments.count == 1,
           let only = call.arguments.first, only.label == nil {
            return only.expression
        }
        if let member = expr.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "magnitude", let base = member.base {
            return base
        }
        return nil
    }
}
